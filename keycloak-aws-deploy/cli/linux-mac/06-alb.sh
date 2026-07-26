#!/usr/bin/env bash
# Creates the ALB, the target group with health checks, and both listeners.
. "$(dirname "$0")/lib/common.sh"
load_config
require_state VPC_ID PUB_A PUB_B SG_ALB

# ---------- load balancer ----------
if already_done ALB_ARN; then
  warn "ALB already recorded - skipping"
else
  step "Creating the Application Load Balancer"
  ALB_ARN=$(aws elbv2 create-load-balancer \
    --name "${PROJECT}-alb" --type application --scheme internet-facing \
    --ip-address-type ipv4 \
    --subnets "$PUB_A" "$PUB_B" --security-groups "$SG_ALB" \
    --tags "Key=Project,Value=${PROJECT}" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text)
  save ALB_ARN "$ALB_ARN"
fi

ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].DNSName' --output text)
save ALB_DNS "$ALB_DNS"
ALB_ZONE=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].CanonicalHostedZoneId' --output text)
save ALB_ZONE "$ALB_ZONE"

step "Applying ALB hardening attributes"
aws elbv2 modify-load-balancer-attributes --load-balancer-arn "$ALB_ARN" \
  --attributes \
    Key=routing.http.drop_invalid_header_fields.enabled,Value=true \
    Key=idle_timeout.timeout_seconds,Value=120 >/dev/null
ok "Invalid headers dropped, idle timeout 120s"

# ---------- target group ----------
if already_done TG_ARN; then
  warn "Target group already recorded - skipping"
else
  step "Creating the target group"
  info "Traffic on 8080, health checks on 9000 /health/ready"
  TG_ARN=$(aws elbv2 create-target-group \
    --name "${PROJECT}-tg" --protocol HTTP --port 8080 \
    --vpc-id "$VPC_ID" --target-type instance \
    --health-check-protocol HTTP \
    --health-check-port 9000 \
    --health-check-path /health/ready \
    --health-check-interval-seconds 15 \
    --health-check-timeout-seconds 5 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 3 \
    --matcher HttpCode=200 \
    --tags "Key=Project,Value=${PROJECT}" \
    --query 'TargetGroups[0].TargetGroupArn' --output text)
  save TG_ARN "$TG_ARN"
fi

step "Enabling sticky sessions and a graceful deregistration delay"
aws elbv2 modify-target-group-attributes --target-group-arn "$TG_ARN" \
  --attributes \
    Key=stickiness.enabled,Value=true \
    Key=stickiness.type,Value=lb_cookie \
    Key=stickiness.lb_cookie.duration_seconds,Value=3600 \
    Key=deregistration_delay.timeout_seconds,Value=60 >/dev/null
ok "Sticky for 1h, 60s drain on removal"

# ---------- listeners ----------
if already_done HTTPS_LISTENER; then
  warn "HTTPS listener already recorded - skipping"
else
  step "Creating the HTTPS listener (TLS 1.2/1.3 only)"
  HTTPS_LISTENER=$(aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" \
    --protocol HTTPS --port 443 \
    --certificates "CertificateArn=$ACM_CERT_ARN" \
    --ssl-policy ELBSecurityPolicy-TLS13-1-2-2021-06 \
    --default-actions "Type=forward,TargetGroupArn=$TG_ARN" \
    --query 'Listeners[0].ListenerArn' --output text)
  save HTTPS_LISTENER "$HTTPS_LISTENER"
fi

if already_done HTTP_LISTENER; then
  warn "HTTP listener already recorded - skipping"
else
  step "Creating the HTTP listener (301 redirect to HTTPS)"
  HTTP_LISTENER=$(aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" \
    --protocol HTTP --port 80 \
    --default-actions '[{"Type":"redirect","RedirectConfig":{"Protocol":"HTTPS","Port":"443","StatusCode":"HTTP_301"}}]' \
    --query 'Listeners[0].ListenerArn' --output text)
  save HTTP_LISTENER "$HTTP_LISTENER"
fi

info "ALB address: $ALB_DNS"
printf '\n%sLoad balancer ready. Next: ./07-launch-template.sh%s\n\n' "$C_GRN$C_BOLD" "$C_RESET"
