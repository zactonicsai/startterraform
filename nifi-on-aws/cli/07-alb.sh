#!/usr/bin/env bash
# ===========================================================================
# The Application Load Balancer.
#
# WHAT IT BUYS YOU
#   - One stable HTTPS address, whichever nodes happen to be alive
#   - TLS termination with a real ACM certificate
#   - Health checks: a node that stops answering stops receiving traffic
#
# TWO NIFI-SPECIFIC REQUIREMENTS PEOPLE MISS
#   1. STICKY SESSIONS ARE MANDATORY. The NiFi UI is a single-page app making
#      many API calls. Bounce those calls between nodes and you get random
#      logouts and half-loaded canvases.
#   2. The ALB's DNS name must appear in nifi.web.proxy.host, or NiFi rejects
#      every request with "Invalid host header".
# ===========================================================================
source "$(dirname "$0")/lib/common.sh"

if ! is_cluster; then
  info "NODE_COUNT=1 - skipping the load balancer"
  cat <<'TXT'
    A single node needs no load balancer. Reach it privately with:

      aws ssm start-session --target <instance-id> \
        --document-name AWS-StartPortForwardingSession \
        --parameters '{"portNumber":["8443"],"localPortNumber":["8443"]}'

    then open https://localhost:8443/nifi

    That is genuinely more secure than an internet-facing endpoint, and free.
TXT
  exit 0
fi

[ -n "${ACM_CERT_ARN:-}" ] || die "ACM_CERT_ARN is required for cluster mode"

info "Load balancer"
if have ALB_ARN; then skip "exists: $ALB_ARN"; else
  ALB_ARN=$(aws elbv2 create-load-balancer \
    --name "$PROJECT-alb" \
    --subnets "$PUBLIC_SUBNET_A" "$PUBLIC_SUBNET_B" \
    --security-groups "$ALB_SG" \
    --scheme internet-facing --type application --ip-address-type ipv4 \
    --tags "Key=Project,Value=$PROJECT" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text)
  remember ALB_ARN "$ALB_ARN"
  ok "created"
fi

ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].DNSName' --output text)
remember ALB_DNS "$ALB_DNS"
ok "DNS: $ALB_DNS"

# Recommended hardening, cheap to set
aws elbv2 modify-load-balancer-attributes --load-balancer-arn "$ALB_ARN" \
  --attributes \
    Key=routing.http.drop_invalid_header_fields.enabled,Value=true \
    Key=routing.http2.enabled,Value=true \
    Key=idle_timeout.timeout_seconds,Value=300 >/dev/null
ok "invalid headers dropped, 300s idle timeout (NiFi UI holds long requests)"

info "Target group"
if have TG_ARN; then skip "exists: $TG_ARN"; else
  # Health check notes:
  #  - protocol HTTPS, because NiFi only speaks HTTPS
  #  - /nifi-api/access/config is one of the few endpoints that answers
  #    WITHOUT a login, which is exactly what a health check needs
  #  - matcher 200-401: if your NiFi version demands auth even here, a 401
  #    still proves the web server is alive. Without this range, an auth
  #    challenge reads as "unhealthy" and the ALB drains every node.
  TG_ARN=$(aws elbv2 create-target-group \
    --name "$PROJECT-tg" \
    --protocol HTTPS --port 8443 --vpc-id "$VPC_ID" \
    --target-type instance \
    --health-check-protocol HTTPS \
    --health-check-path "/nifi-api/access/config" \
    --health-check-interval-seconds 30 \
    --health-check-timeout-seconds 10 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 3 \
    --matcher HttpCode=200-401 \
    --query 'TargetGroups[0].TargetGroupArn' --output text)
  remember TG_ARN "$TG_ARN"
  ok "created with health check /nifi-api/access/config (accepts 200-401)"
fi

info "Stickiness and draining"
aws elbv2 modify-target-group-attributes --target-group-arn "$TG_ARN" \
  --attributes \
    Key=stickiness.enabled,Value=true \
    Key=stickiness.type,Value=lb_cookie \
    Key=stickiness.lb_cookie.duration_seconds,Value=86400 \
    Key=deregistration_delay.timeout_seconds,Value=120 >/dev/null
ok "sticky sessions ON (mandatory for the NiFi UI), 120s draining"

info "Registering nodes"
for i in $(seq 1 "$NODE_COUNT"); do
  eval "id=\${NIFI_INSTANCE_$i:-}"
  [ -z "$id" ] && { warn "node $i not launched yet"; continue; }
  aws elbv2 register-targets --target-group-arn "$TG_ARN" --targets "Id=$id" >/dev/null
  ok "registered $id"
done

info "HTTPS listener"
if have LISTENER_ARN; then skip "exists"; else
  LISTENER_ARN=$(aws elbv2 create-listener \
    --load-balancer-arn "$ALB_ARN" \
    --protocol HTTPS --port 443 \
    --certificates "CertificateArn=$ACM_CERT_ARN" \
    --ssl-policy ELBSecurityPolicy-TLS13-1-2-2021-06 \
    --default-actions "Type=forward,TargetGroupArn=$TG_ARN" \
    --query 'Listeners[0].ListenerArn' --output text)
  remember LISTENER_ARN "$LISTENER_ARN"
  ok "443 -> target group, TLS 1.2/1.3 only"
fi

if [ -n "${HOSTED_ZONE_ID:-}" ] && [ -n "${NIFI_HOSTNAME:-}" ]; then
  info "Route 53 alias"
  ZONE=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
    --query 'LoadBalancers[0].CanonicalHostedZoneId' --output text)
  cat > "$STATE_DIR/dns.json" << JSON
{"Changes":[{"Action":"UPSERT","ResourceRecordSet":{
  "Name":"$NIFI_HOSTNAME","Type":"A",
  "AliasTarget":{"HostedZoneId":"$ZONE","DNSName":"$ALB_DNS","EvaluateTargetHealth":true}}}]}
JSON
  aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" \
    --change-batch "file://$STATE_DIR/dns.json" >/dev/null
  ok "$NIFI_HOSTNAME -> $ALB_DNS"
fi

cat <<TXT

    ------------------------------------------------------------------
     NOW DO THIS, or the UI will not load:

     The nodes were started before the ALB existed, so its DNS name is
     not yet in nifi.web.proxy.host. Push it to them:

         ./06-nifi-nodes.sh --refresh-proxy

     Then wait ~2 minutes and check:

         ./08-verify.sh
    ------------------------------------------------------------------
TXT
