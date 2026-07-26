#!/usr/bin/env bash
# Finds resources that survive a teardown and quietly keep billing.
. "$(dirname "$0")/lib/common.sh"
load_config

hunt() { step "$1"; shift; "$@" || warn "query failed"; }

hunt "EC2 instances (any non-terminated state)" \
  aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=${PROJECT}" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].[InstanceId,State.Name,InstanceType]' --output table

hunt "Unattached EBS volumes (~\$0.08/GB-month, silent)" \
  aws ec2 describe-volumes --filters "Name=status,Values=available" \
    --query 'Volumes[].[VolumeId,Size,CreateTime]' --output table

hunt "EBS snapshots you own (~\$0.05/GB-month)" \
  aws ec2 describe-snapshots --owner-ids self \
    --query 'Snapshots[].[SnapshotId,VolumeSize,StartTime]' --output table

hunt "Unassociated Elastic IPs (~\$3.60/month EACH)" \
  aws ec2 describe-addresses \
    --query 'Addresses[?AssociationId==null].[PublicIp,AllocationId]' --output table

hunt "NAT gateways (~\$35/month EACH - the usual culprit)" \
  aws ec2 describe-nat-gateways --filter "Name=state,Values=pending,available" \
    --query 'NatGateways[].[NatGatewayId,State,VpcId]' --output table

hunt "Load balancers (~\$20/month, runs happily with zero targets)" \
  aws elbv2 describe-load-balancers \
    --query 'LoadBalancers[].[LoadBalancerName,State.Code,Type]' --output table

hunt "Target groups" \
  aws elbv2 describe-target-groups --query 'TargetGroups[].TargetGroupName' --output table

hunt "RDS instances" \
  aws rds describe-db-instances \
    --query 'DBInstances[].[DBInstanceIdentifier,DBInstanceStatus,MultiAZ,DBInstanceClass]' --output table

hunt "Manual RDS snapshots (kept on purpose - ~\$0.095/GB-month)" \
  aws rds describe-db-snapshots --snapshot-type manual \
    --query 'DBSnapshots[].[DBSnapshotIdentifier,AllocatedStorage,SnapshotCreateTime]' --output table

hunt "Secrets, including those scheduled for deletion" \
  aws secretsmanager list-secrets --include-planned-deletion \
    --query 'SecretList[].[Name,DeletedDate]' --output table

hunt "CloudWatch log groups (default retention: NEVER EXPIRE)" \
  aws logs describe-log-groups --log-group-name-prefix "/${PROJECT}" \
    --query 'logGroups[].[logGroupName,storedBytes,retentionInDays]' --output table

hunt "VPCs" \
  aws ec2 describe-vpcs --query 'Vpcs[].[VpcId,CidrBlock,IsDefault]' --output table

hunt "Launch templates" \
  aws ec2 describe-launch-templates \
    --query 'LaunchTemplates[].[LaunchTemplateName,CreateTime]' --output table 2>/dev/null

step "CATCH-ALL: anything still tagged Project=${PROJECT}"
info "If you tagged consistently, this finds everything in one shot."
REMAIN=$(aws resourcegroupstaggingapi get-resources \
  --tag-filters "Key=Project,Values=${PROJECT}" \
  --query 'ResourceTagMappingList[].ResourceARN' --output text)
if [ -z "$REMAIN" ]; then
  ok "Nothing left tagged with this project."
else
  printf '%s\n' "$REMAIN" | tr '\t' '\n'
  warn "The ARNs above are still present."
fi

step "Yesterday's spend by service"
aws ce get-cost-and-usage \
  --time-period "Start=$(date -u -d '2 days ago' +%Y-%m-%d 2>/dev/null || date -u -v-2d +%Y-%m-%d),End=$(date -u +%Y-%m-%d)" \
  --granularity DAILY --metrics UnblendedCost \
  --group-by Type=DIMENSION,Key=SERVICE \
  --query 'ResultsByTime[].Groups[?Metrics.UnblendedCost.Amount!=`0`].[Keys[0],Metrics.UnblendedCost.Amount]' \
  --output text 2>/dev/null || warn "Cost Explorer not enabled, or no ce:GetCostAndUsage permission."

printf '\n%sRe-run this in 48 hours - AWS billing data lags by up to a day.%s\n\n' "$C_YEL" "$C_RESET"
