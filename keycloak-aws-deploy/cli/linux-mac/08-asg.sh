#!/usr/bin/env bash
# Creates the Auto Scaling Group, the scaling policy and the CloudWatch alarms.
. "$(dirname "$0")/lib/common.sh"
load_config
require_state LT_ID APP_A APP_B TG_ARN ALB_ARN

ASG_NAME="${PROJECT}-asg"
save ASG_NAME "$ASG_NAME"

if aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" \
     --query 'AutoScalingGroups[0].AutoScalingGroupName' --output text 2>/dev/null | grep -q "$ASG_NAME"; then
  warn "ASG already exists - updating it instead of creating"
  aws autoscaling update-auto-scaling-group \
    --auto-scaling-group-name "$ASG_NAME" \
    --min-size "${ASG_MIN}" --max-size "${ASG_MAX}" \
    --health-check-type ELB --health-check-grace-period 300
else
  step "Creating the Auto Scaling Group"
  info "min=$ASG_MIN max=$ASG_MAX across 2 AZs, health checks from the ALB"
  aws autoscaling create-auto-scaling-group \
    --auto-scaling-group-name "$ASG_NAME" \
    --launch-template "LaunchTemplateId=${LT_ID},Version=\$Latest" \
    --min-size "${ASG_MIN}" --max-size "${ASG_MAX}" --desired-capacity "${ASG_MIN}" \
    --vpc-zone-identifier "${APP_A},${APP_B}" \
    --target-group-arns "$TG_ARN" \
    --health-check-type ELB \
    --health-check-grace-period 300 \
    --default-instance-warmup 300 \
    --termination-policies "OldestInstance" \
    --tags \
      "Key=Name,Value=${PROJECT}-node,PropagateAtLaunch=true" \
      "Key=Project,Value=${PROJECT},PropagateAtLaunch=true"
  ok "ASG created - instances are launching now"
fi

step "Adding a CPU target-tracking scaling policy (target 60%)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/policy.json" << 'JSON'
{
  "TargetValue": 60.0,
  "PredefinedMetricSpecification": {
    "PredefinedMetricType": "ASGAverageCPUUtilization"
  },
  "DisableScaleIn": false
}
JSON
aws autoscaling put-scaling-policy \
  --auto-scaling-group-name "$ASG_NAME" \
  --policy-name "${PROJECT}-cpu-target" \
  --policy-type TargetTrackingScaling \
  --estimated-instance-warmup 300 \
  --target-tracking-configuration "file://$TMP/policy.json" >/dev/null
ok "Works like a thermostat: 60% leaves headroom for the ~3min boot time"

step "Creating CloudWatch alarms"
ALB_SUFFIX=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text | sed 's|.*:loadbalancer/||')
TG_SUFFIX=$(echo "$TG_ARN" | sed 's|.*:||')
DIMS="Name=LoadBalancer,Value=${ALB_SUFFIX} Name=TargetGroup,Value=${TG_SUFFIX}"

aws cloudwatch put-metric-alarm \
  --alarm-name "${PROJECT}-NO-healthy-hosts-CRITICAL" \
  --alarm-description "No healthy Keycloak instances - total outage" \
  --namespace AWS/ApplicationELB --metric-name HealthyHostCount \
  --statistic Minimum --period 60 --evaluation-periods 1 \
  --threshold 1 --comparison-operator LessThanThreshold \
  --treat-missing-data breaching \
  --dimensions $DIMS \
  --tags "Key=Project,Value=${PROJECT}"
ok "${PROJECT}-NO-healthy-hosts-CRITICAL"

aws cloudwatch put-metric-alarm \
  --alarm-name "${PROJECT}-unhealthy-hosts" \
  --alarm-description "At least one Keycloak instance is unhealthy" \
  --namespace AWS/ApplicationELB --metric-name UnHealthyHostCount \
  --statistic Average --period 60 --evaluation-periods 2 \
  --threshold 0 --comparison-operator GreaterThanThreshold \
  --treat-missing-data notBreaching \
  --dimensions $DIMS \
  --tags "Key=Project,Value=${PROJECT}"
ok "${PROJECT}-unhealthy-hosts"

aws cloudwatch put-metric-alarm \
  --alarm-name "${PROJECT}-db-cpu-high" \
  --alarm-description "RDS CPU above 80% for 15 minutes" \
  --namespace AWS/RDS --metric-name CPUUtilization \
  --statistic Average --period 300 --evaluation-periods 3 \
  --threshold 80 --comparison-operator GreaterThanThreshold \
  --dimensions "Name=DBInstanceIdentifier,Value=${DB_ID}" \
  --tags "Key=Project,Value=${PROJECT}"
ok "${PROJECT}-db-cpu-high"

warn "Alarms have NO notification target. Attach an SNS topic with --alarm-actions"
warn "or they will fire silently into the void."

printf '\n%sASG ready. Next: ./09-dns.sh (or skip to ./10-verify.sh)%s\n\n' "$C_GRN$C_BOLD" "$C_RESET"
