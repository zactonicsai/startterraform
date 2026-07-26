#!/usr/bin/env bash
# End-to-end verification. Safe to run repeatedly.
. "$(dirname "$0")/lib/common.sh"
load_config
require_state ASG_NAME TG_ARN ALB_DNS

step "ASG instances"
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" \
  --query 'AutoScalingGroups[0].Instances[].{Id:InstanceId,AZ:AvailabilityZone,Health:HealthStatus,State:LifecycleState}' \
  --output table

step "Target group health (the number that actually matters)"
aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].{Target:Target.Id,Port:Target.Port,State:TargetHealth.State,Reason:TargetHealth.Reason,Desc:TargetHealth.Description}' \
  --output table

HEALTHY=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
  --query 'length(TargetHealthDescriptions[?TargetHealth.State==`healthy`])' --output text)
info "Healthy targets: $HEALTHY"

if [ "$HEALTHY" = "0" ]; then
  warn "No healthy targets yet."
  info "First boot takes 4-6 minutes (image pull + JVM start + schema creation)."
  info "If it stays at 0, check in this order:"
  info "  1. KC_HEALTH_ENABLED=true in the user-data      (most common cause)"
  info "  2. app SG allows port 9000 from the ALB SG"
  info "  3. health-check-grace-period >= 300"
  info "  4. read the boot log:  ./troubleshoot.sh logs"
  echo
fi

step "Recent scaling activity"
aws autoscaling describe-scaling-activities --auto-scaling-group-name "$ASG_NAME" \
  --max-records 5 --query 'Activities[].{Status:StatusCode,Cause:Description}' --output table

step "HTTP -> HTTPS redirect"
curl -s -o /dev/null -D - "http://${DOMAIN_NAME}" 2>/dev/null | head -5 || warn "Could not reach http://${DOMAIN_NAME}"

step "Keycloak OIDC discovery document"
ISSUER=$(curl -fsS --max-time 15 \
  "https://${DOMAIN_NAME}/realms/master/.well-known/openid-configuration" 2>/dev/null \
  | jq -r '.issuer' 2>/dev/null || echo "")
if [ "$ISSUER" = "https://${DOMAIN_NAME}/realms/master" ]; then
  ok "Issuer is correct: $ISSUER"
elif [ -n "$ISSUER" ]; then
  warn "Issuer is WRONG: $ISSUER"
  info "Expected: https://${DOMAIN_NAME}/realms/master"
  info "Fix KC_HOSTNAME, re-run 07-launch-template.sh, then start an instance refresh."
else
  warn "Could not fetch the discovery document yet (DNS or startup still in progress)"
  info "Try the ALB directly:  curl -k https://${ALB_DNS}/realms/master"
fi

step "Bootstrap admin credentials"
if [ -n "${KC_SECRET_ARN:-}" ]; then
  info "aws secretsmanager get-secret-value --secret-id '$KC_SECRET_ARN' --query SecretString --output text | jq"
fi

cat << TXT

  ${C_BOLD}Admin console:${C_RESET} https://${DOMAIN_NAME}/admin

  ${C_YEL}${C_BOLD}Do this immediately after your first login:${C_RESET}
    1. create a real named admin account and enable OTP/MFA on it
    2. delete the 'tmpadmin' bootstrap user
    3. delete the bootstrap secret
    4. create a separate realm for your applications - never use 'master'

TXT
