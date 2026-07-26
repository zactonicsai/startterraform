#!/usr/bin/env bash
# ===========================================================================
# Prove it works, in the order that isolates faults fastest.
# ===========================================================================
source "$(dirname "$0")/lib/common.sh"

FAIL=0

info "1. Instances running?"
for i in $(seq 1 "$NODE_COUNT"); do
  eval "id=\${NIFI_INSTANCE_$i:-}"
  [ -z "$id" ] && { warn "node $i not recorded"; FAIL=1; continue; }
  read -r st ip < <(aws ec2 describe-instances --instance-ids "$id" \
    --query 'Reservations[0].Instances[0].[State.Name,PrivateIpAddress]' --output text)
  [ "$st" = running ] && ok "node $i ($id) $st at $ip" || { warn "node $i is $st"; FAIL=1; }
done

info "2. Did the bootstrap script finish?"
for i in $(seq 1 "$NODE_COUNT"); do
  eval "id=\${NIFI_INSTANCE_$i:-}"; [ -z "$id" ] && continue
  CMD=$(aws ssm send-command --instance-ids "$id" \
    --document-name AWS-RunShellScript \
    --parameters 'commands=["tail -3 /var/log/nifi-bootstrap.log","docker ps --format {{.Names}}:{{.Status}}"]' \
    --query 'Command.CommandId' --output text 2>/dev/null) || { warn "node $i: SSM not ready yet"; continue; }
  sleep 6
  OUT=$(aws ssm get-command-invocation --command-id "$CMD" --instance-id "$id" \
    --query 'StandardOutputContent' --output text 2>/dev/null || echo "")
  if echo "$OUT" | grep -q "NiFi READY"; then ok "node $i: bootstrap completed"
  elif echo "$OUT" | grep -q "nifi:Up"; then ok "node $i: container up"
  else warn "node $i: not ready yet -"; printf '        %s\n' "$(echo "$OUT" | tail -2)"; FAIL=1; fi
done

if is_cluster; then
  info "3. Load balancer target health - the check that actually matters"
  aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
    --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Reason]' \
    --output text | while read -r id state reason; do
      if [ "$state" = healthy ]; then ok "$id healthy"
      else warn "$id $state ${reason:-}"; fi
    done
  H=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
    --query 'length(TargetHealthDescriptions[?TargetHealth.State==`healthy`])' --output text)
  [ "${H:-0}" -ge 1 ] || { warn "NO healthy targets - the UI will return 503"; FAIL=1; }

  info "4. Does the endpoint answer?"
  URL="https://${NIFI_HOSTNAME:-$ALB_DNS}"
  CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$URL/nifi-api/access/config" || echo 000)
  case "$CODE" in
    200|401) ok "$URL/nifi-api/access/config -> $CODE (web layer alive)" ;;
    503) warn "503 - no healthy targets behind the ALB"; FAIL=1 ;;
    000) warn "no response - check the ALB security group allows $MY_IP_CIDR"; FAIL=1 ;;
    *)   warn "unexpected HTTP $CODE"; FAIL=1 ;;
  esac

  info "5. Cluster membership"
  warn "This needs a login. After signing in to the UI, check:"
  warn "  hamburger menu -> Cluster. All $NODE_COUNT nodes should be CONNECTED,"
  warn "  exactly one marked Primary and one Coordinator."
  warn "Nodes stuck at 'Connecting' almost always mean port 11443 is blocked"
  warn "  or NIFI_CLUSTER_ADDRESS is not resolvable between nodes."

  echo
  ok "Open: $URL/nifi"
  ok "Login: admin / \$(aws secretsmanager get-secret-value --secret-id $PROJECT/nifi-admin --query SecretString --output text | jq -r .password)"
else
  info "3. Reaching a single private node"
  eval "id=\$NIFI_INSTANCE_1"
  cat <<TXT
    No load balancer and no open port. Tunnel in:

      aws ssm start-session --target $id \\
        --document-name AWS-StartPortForwardingSession \\
        --parameters '{"portNumber":["8443"],"localPortNumber":["8443"]}'

    Leave that running, then in another terminal / your browser:

      https://localhost:8443/nifi

    Password:
      aws secretsmanager get-secret-value --secret-id $PROJECT/nifi-admin \\
        --query SecretString --output text | jq -r .password
TXT
fi

echo
[ "$FAIL" -eq 0 ] && ok "VERIFY PASSED" || warn "Some checks failed - run ./troubleshoot.sh"
