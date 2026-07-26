#!/usr/bin/env bash
# Runs the whole build in order. Each step is re-runnable.
. "$(dirname "$0")/lib/common.sh"
load_config

printf '%s\n' "=============================================================="
printf '  Keycloak on AWS - full deployment\n'
printf '  Project : %s\n' "$PROJECT"
printf '  Region  : %s\n' "$AWS_REGION"
printf '  Domain  : %s\n' "$DOMAIN_NAME"
printf '%s\n' "=============================================================="
echo
warn "This creates billable AWS resources (~\$290-320/month for the full HA stack)."
warn "Estimated time: 20-30 minutes, mostly waiting for RDS."
confirm "Continue? Type yes:"

START=$(date +%s)
for s in 00-preflight 01-network 02-security-groups 03-secrets 04-iam \
         05-rds 06-alb 07-launch-template 08-asg 09-dns; do
  printf '\n%s############ %s ############%s\n' "$C_BOLD" "$s" "$C_RESET"
  "$(dirname "$0")/${s}.sh" || die "Step $s failed. Fix the problem and re-run: ./${s}.sh"
done

printf '\n%s############ waiting for instances to become healthy ############%s\n' "$C_BOLD" "$C_RESET"
load_state
for i in $(seq 1 40); do
  H=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
    --query 'length(TargetHealthDescriptions[?TargetHealth.State==`healthy`])' --output text 2>/dev/null || echo 0)
  printf '  healthy targets: %s  (%ss elapsed)\n' "$H" "$((i*15))"
  [ "$H" -ge 1 ] && break
  sleep 15
done

"$(dirname "$0")/10-verify.sh" || true
END=$(date +%s)
printf '\n%sDeployment finished in %s minutes.%s\n' "$C_GRN$C_BOLD" "$(( (END-START)/60 ))" "$C_RESET"
printf 'State saved to: %s\n\n' "$STATE_FILE"
