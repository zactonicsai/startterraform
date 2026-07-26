#!/usr/bin/env bash
# Tears everything down in the correct dependency order: inside out.
# Deliberately interactive. Read every prompt.
. "$(dirname "$0")/lib/common.sh"
load_config; load_state

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

cat << TXT
==============================================================
  ${C_RED}${C_BOLD}DESTROY${C_RESET} - Keycloak on AWS
  Project : $PROJECT
  Region  : $AWS_REGION
  Account : $ACCOUNT
==============================================================

  Order (each depends on the previous):
    1. ASG to zero, wait for instances to drain
    2. Delete ASG + scaling policy
    3. Delete launch template
    4. Delete ALB listeners
    5. Delete ALB, wait for network interfaces to release
    6. Delete target group
    7. RDS: disable deletion protection, delete WITH final snapshot
    8. Delete DB subnet group
    9. Delete NAT gateways, wait
   10. Release Elastic IPs
   11. Delete route tables and subnets
   12. Detach + delete internet gateway
   13. Revoke cross-referencing SG rules, delete security groups
   14. Delete VPC
   15. IAM role + instance profile
   16. Schedule secret deletion
   17. Route 53 record, log groups, alarms

TXT

warn "Have you run ./pre-destroy-backup.sh ?"
confirm "Type the project name to confirm you mean THIS stack:" "$PROJECT"
confirm "Last chance. Type DESTROY:" "DESTROY"

# tolerate already-deleted resources
try() { "$@" >/dev/null 2>&1 && ok "$*" || warn "skipped/failed: $*"; }

# ---------- 1-2. ASG ----------
if [ -n "${ASG_NAME:-}" ]; then
  step "1. Scaling the ASG to zero"
  if aws autoscaling update-auto-scaling-group --auto-scaling-group-name "$ASG_NAME" \
       --min-size 0 --max-size 0 --desired-capacity 0 2>/dev/null; then
    info "Waiting for instances to terminate gracefully..."
    for i in $(seq 1 60); do
      C=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" \
        --query 'length(AutoScalingGroups[0].Instances)' --output text 2>/dev/null || echo 0)
      printf '  instances remaining: %s\n' "$C"
      [ "$C" = "0" ] && break
      sleep 15
    done
    ok "Drained"
  else
    warn "ASG not found"
  fi

  step "2. Deleting the ASG"
  try aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "$ASG_NAME" --force-delete
  info "Waiting for the ASG to fully disappear..."
  for i in $(seq 1 30); do
    aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" \
      --query 'AutoScalingGroups[0]' --output text 2>/dev/null | grep -q . || break
    sleep 10
  done
fi

# ---------- 3. launch template ----------
if [ -n "${LT_ID:-}" ]; then
  step "3. Deleting the launch template"
  try aws ec2 delete-launch-template --launch-template-id "$LT_ID"
fi

# ---------- 4-6. ALB ----------
if [ -n "${HTTPS_LISTENER:-}" ]; then
  step "4. Deleting listeners"
  try aws elbv2 delete-listener --listener-arn "$HTTPS_LISTENER"
  [ -n "${HTTP_LISTENER:-}" ] && try aws elbv2 delete-listener --listener-arn "$HTTP_LISTENER"
fi

if [ -n "${ALB_ARN:-}" ]; then
  step "5. Deleting the load balancer"
  try aws elbv2 modify-load-balancer-attributes --load-balancer-arn "$ALB_ARN" \
    --attributes Key=deletion_protection.enabled,Value=false
  try aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN"
  info "Waiting for the ALB and its network interfaces to release..."
  aws elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB_ARN" 2>/dev/null || true
  info "Extra 60s grace - ENIs linger after the API reports 'deleted'."
  info "Skipping this wait is the #1 cause of DependencyViolation errors later."
  sleep 60
  ok "ALB gone"
fi

if [ -n "${TG_ARN:-}" ]; then
  step "6. Deleting the target group"
  try aws elbv2 delete-target-group --target-group-arn "$TG_ARN"
fi

# ---------- 7-8. RDS ----------
if [ -n "${DB_ID:-}" ] && aws rds describe-db-instances --db-instance-identifier "$DB_ID" >/dev/null 2>&1; then
  step "7. Deleting the RDS database"
  cat << TXT

  ${C_YEL}${C_BOLD}This is the only irreplaceable resource in the stack.${C_RESET}

    snapshot  - delete but take a final snapshot first  (recommended, safe)
    nuke      - delete with NO snapshot                 (permanent, no undo)
    keep      - leave the database running              (skip this step)

TXT
  printf '%sChoose [snapshot/nuke/keep]:%s ' "$C_YEL$C_BOLD" "$C_RESET"
  read -r CHOICE

  case "$CHOICE" in
    keep)
      warn "Database kept. It will keep costing money (~\$130/mo Multi-AZ)."
      warn "Its subnet group and security group cannot be deleted while it exists."
      ;;
    snapshot|nuke)
      info "Removing deletion protection (a deliberate act)..."
      aws rds modify-db-instance --db-instance-identifier "$DB_ID" \
        --no-deletion-protection --apply-immediately >/dev/null
      aws rds wait db-instance-available --db-instance-identifier "$DB_ID"
      ok "Deletion protection off"

      if [ "$CHOICE" = "snapshot" ]; then
        FINAL="${PROJECT}-final-$(date -u +%Y%m%d-%H%M%S)"
        aws rds delete-db-instance --db-instance-identifier "$DB_ID" \
          --final-db-snapshot-identifier "$FINAL" >/dev/null
        save FINAL_SNAPSHOT "$FINAL"
        printf '\n  %sFinal snapshot: %s%s\n' "$C_BOLD" "$FINAL" "$C_RESET"
        printf '  WRITE THAT DOWN. Keep the DB secret at least as long as the snapshot,\n'
        printf '  or you will have an encrypted box you cannot open.\n\n'
      else
        confirm "Permanent deletion, no backup. Type NUKE:" "NUKE"
        aws rds delete-db-instance --db-instance-identifier "$DB_ID" \
          --skip-final-snapshot --delete-automated-backups >/dev/null
        warn "No snapshot taken. This data is gone forever."
      fi

      info "Waiting for deletion (10-20 min if taking a final snapshot)..."
      aws rds wait db-instance-deleted --db-instance-identifier "$DB_ID" 2>/dev/null || true
      ok "Database deleted"

      step "8. Deleting the DB subnet group"
      try aws rds delete-db-subnet-group --db-subnet-group-name "${DB_SUBNET_GROUP:-${PROJECT}-db-subnets}"
      ;;
    *) die "Unrecognised choice '$CHOICE'. Nothing deleted. Re-run when ready." ;;
  esac
fi

# ---------- 9-10. NAT + EIP ----------
NATS=""
[ -n "${NAT_A:-}" ] && NATS="$NAT_A"
[ -n "${NAT_B:-}" ] && [ "${NAT_B:-}" != "${NAT_A:-}" ] && NATS="$NATS $NAT_B"
if [ -n "$NATS" ]; then
  step "9. Deleting NAT gateways (the expensive ones - ~\$35/mo each)"
  for N in $NATS; do try aws ec2 delete-nat-gateway --nat-gateway-id "$N"; done
  info "Waiting for deletion (2-5 minutes)..."
  # shellcheck disable=SC2086
  aws ec2 wait nat-gateway-deleted --nat-gateway-ids $NATS 2>/dev/null || true
  ok "NAT gateways gone"
fi

step "10. Releasing Elastic IPs (an idle EIP still costs ~\$3.60/mo)"
info "Order matters: you cannot release an EIP attached to a live NAT gateway."
for E in "${EIP_A:-}" "${EIP_B:-}"; do
  [ -n "$E" ] && try aws ec2 release-address --allocation-id "$E"
done

# ---------- 11. route tables + subnets ----------
step "11. Deleting route tables"
for RTB in "${RTB_PUB:-}" "${RTB_A:-}" "${RTB_B:-}"; do
  [ -z "$RTB" ] && continue
  ASSOCS=$(aws ec2 describe-route-tables --route-table-ids "$RTB" \
    --query 'RouteTables[0].Associations[?!Main].RouteTableAssociationId' \
    --output text 2>/dev/null || true)
  for A in $ASSOCS; do try aws ec2 disassociate-route-table --association-id "$A"; done
  try aws ec2 delete-route-table --route-table-id "$RTB"
done

step "11b. Deleting subnets"
for S in "${PUB_A:-}" "${PUB_B:-}" "${APP_A:-}" "${APP_B:-}" "${DB_A:-}" "${DB_B:-}"; do
  [ -n "$S" ] && try aws ec2 delete-subnet --subnet-id "$S"
done

# ---------- 12. IGW ----------
if [ -n "${IGW_ID:-}" ] && [ -n "${VPC_ID:-}" ]; then
  step "12. Detaching and deleting the internet gateway"
  try aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
  try aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID"
fi

# ---------- 13. security groups ----------
step "13. Revoking cross-references, then deleting security groups"
info "They reference each other, so the rules must go before the groups."
revoke() { aws ec2 revoke-security-group-ingress --group-id "$1" \
  --ip-permissions "IpProtocol=tcp,FromPort=$2,ToPort=$3,UserIdGroupPairs=[{GroupId=$4}]" \
  >/dev/null 2>&1 && ok "revoked $2 on $1" || true; }
[ -n "${SG_RDS:-}" ] && [ -n "${SG_APP:-}" ] && revoke "$SG_RDS" 5432 5432 "$SG_APP"
[ -n "${SG_APP:-}" ] && [ -n "${SG_ALB:-}" ] && { revoke "$SG_APP" 8080 8080 "$SG_ALB"; revoke "$SG_APP" 9000 9000 "$SG_ALB"; }
[ -n "${SG_APP:-}" ] && revoke "$SG_APP" 7800 7801 "$SG_APP"

for SG in "${SG_RDS:-}" "${SG_APP:-}" "${SG_ALB:-}"; do
  [ -z "$SG" ] && continue
  for attempt in 1 2 3 4 5 6; do
    if aws ec2 delete-security-group --group-id "$SG" >/dev/null 2>&1; then
      ok "deleted $SG"; break
    fi
    warn "DependencyViolation on $SG - a leftover ENI is still using it. Retry $attempt/6 in 30s"
    sleep 30
  done
done

# ---------- 14. VPC ----------
if [ -n "${VPC_ID:-}" ]; then
  step "14. Deleting the VPC"
  if aws ec2 delete-vpc --vpc-id "$VPC_ID" 2>/dev/null; then
    ok "VPC deleted"
  else
    warn "VPC would not delete - something is still inside it."
    info "Leftover network interfaces:"
    aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC_ID" \
      --query 'NetworkInterfaces[].[NetworkInterfaceId,Description,Status]' --output table || true
    info "Wait a few minutes and re-run this script, or delete the ENIs by hand."
  fi
fi

# ---------- 15. IAM ----------
if [ -n "${ROLE_NAME:-}" ]; then
  step "15. Deleting the IAM role and instance profile"
  info "Order: remove role from profile -> delete profile -> detach policies -> delete role"
  try aws iam remove-role-from-instance-profile --instance-profile-name "$ROLE_NAME" --role-name "$ROLE_NAME"
  try aws iam delete-instance-profile --instance-profile-name "$ROLE_NAME"
  try aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "${PROJECT}-read-secrets"
  for P in AmazonSSMManagedInstanceCore CloudWatchAgentServerPolicy; do
    try aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "arn:aws:iam::aws:policy/$P"
  done
  try aws iam delete-role --role-name "$ROLE_NAME"
fi

# ---------- 16. secrets ----------
step "16. Scheduling secret deletion"
cat << TXT
  Keeping the DB credentials for 30 days on purpose: if you ever restore
  the final snapshot you will need that master password.
TXT
[ -n "${DB_SECRET_ARN:-}" ]  && try aws secretsmanager delete-secret --secret-id "$DB_SECRET_ARN"  --recovery-window-in-days 30
[ -n "${ART_SECRET_ARN:-}" ] && try aws secretsmanager delete-secret --secret-id "$ART_SECRET_ARN" --recovery-window-in-days 7
[ -n "${KC_SECRET_ARN:-}" ]  && try aws secretsmanager delete-secret --secret-id "$KC_SECRET_ARN"  --recovery-window-in-days 7

# ---------- 17. DNS, logs, alarms ----------
if [ "${DNS_RECORD_CREATED:-no}" = "yes" ] && [ -n "${HOSTED_ZONE_ID:-}" ]; then
  step "17. Deleting the Route 53 alias record"
  TMP=$(mktemp -d)
  cat > "$TMP/del.json" << JSON
{"Changes":[{"Action":"DELETE","ResourceRecordSet":{
  "Name":"${DOMAIN_NAME}","Type":"A",
  "AliasTarget":{"HostedZoneId":"${ALB_ZONE}","DNSName":"${ALB_DNS}","EvaluateTargetHealth":true}}}]}
JSON
  try aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" --change-batch "file://$TMP/del.json"
  rm -rf "$TMP"
fi

step "17b. Deleting CloudWatch log groups"
info "These are NOT managed by the deploy scripts' state - the Docker awslogs"
info "driver may have auto-created them. Default retention is 'never expire'."
try aws logs delete-log-group --log-group-name "${LOG_GROUP:-/${PROJECT}/keycloak}"
try aws logs delete-log-group --log-group-name "/aws/vpc/${PROJECT}/flow-logs"

step "17c. Deleting alarms"
try aws cloudwatch delete-alarms --alarm-names \
  "${PROJECT}-NO-healthy-hosts-CRITICAL" "${PROJECT}-unhealthy-hosts" "${PROJECT}-db-cpu-high"

# ---------- done ----------
mv "$STATE_FILE" "$STATE_FILE.destroyed-$(date -u +%Y%m%d-%H%M%S)" 2>/dev/null || true

cat << TXT

${C_GRN}${C_BOLD}Teardown complete.${C_RESET}

  Next, and do not skip this:
    ${C_BOLD}./orphan-hunt.sh${C_RESET}          find anything still billing
    check the bill in 48h    AWS billing data lags by up to a day

  Deliberately kept:
    - RDS snapshots (manual + final)   ~\$0.095/GB-month
    - Secrets in their recovery window
  Delete those separately once you are certain you will not need them.

TXT
