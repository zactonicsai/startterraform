#!/usr/bin/env bash
# ===========================================================================
# Find what survived the teardown and is still costing money.
# Run this after destroy-all.sh, every time.
# ===========================================================================
source "$(dirname "$0")/lib/common.sh" 2>/dev/null || {
  PROJECT="${PROJECT:-nifi-demo}"; AWS_REGION="${AWS_REGION:-eu-west-1}"
  export AWS_DEFAULT_REGION="$AWS_REGION"
  info() { printf '\n==> %s\n' "$*"; }
  ok()   { printf '    [ok] %s\n' "$*"; }
  warn() { printf '    [!] %s\n' "$*"; }
}

FOUND=0
hunt() {  # hunt <label> <monthly cost hint> <aws command...>
  local label="$1" cost="$2"; shift 2
  local out
  out=$("$@" 2>/dev/null || true)
  if [ -n "$out" ] && [ "$out" != "None" ]; then
    warn "$label  (~$cost)"
    echo "$out" | sed 's/^/        /'
    FOUND=$((FOUND+1))
  else
    ok "$label: none"
  fi
}

echo "==========================================================================="
echo "  Orphan hunt for '$PROJECT' in $AWS_REGION"
echo "==========================================================================="

info "The expensive ones"
hunt "Unassociated Elastic IPs" '$3.60/mo each' \
  aws ec2 describe-addresses --query 'Addresses[?AssociationId==`null`].[PublicIp,AllocationId]' --output text
hunt "NAT Gateways" '$32/mo each' \
  aws ec2 describe-nat-gateways --filter Name=state,Values=available,pending \
    --query 'NatGateways[].[NatGatewayId,State]' --output text
hunt "Load balancers" '$18/mo each' \
  aws elbv2 describe-load-balancers --query 'LoadBalancers[].[LoadBalancerName,State.Code]' --output text
hunt "Available (unattached) EBS volumes" '$0.08/GB/mo' \
  aws ec2 describe-volumes --filters Name=status,Values=available \
    --query 'Volumes[].[VolumeId,Size,CreateTime]' --output text
hunt "Running instances tagged $PROJECT" 'varies' \
  aws ec2 describe-instances --filters "Name=tag:Project,Values=$PROJECT" \
    "Name=instance-state-name,Values=running,pending,stopped" \
    --query 'Reservations[].Instances[].[InstanceId,State.Name,InstanceType]' --output text

info "The quiet ones"
hunt "EBS snapshots" '$0.05/GB/mo' \
  aws ec2 describe-snapshots --owner-ids self --filters "Name=tag:Project,Values=$PROJECT" \
    --query 'Snapshots[].[SnapshotId,VolumeSize,State,StartTime]' --output text
hunt "Log groups with NO retention (bill forever)" 'grows forever' \
  aws logs describe-log-groups --query 'logGroups[?retentionInDays==`null`].[logGroupName,storedBytes]' --output text
hunt "Secrets pending deletion (names stay reserved)" '$0.40/mo each' \
  aws secretsmanager list-secrets --include-planned-deletion \
    --query "SecretList[?starts_with(Name, '$PROJECT')].[Name,DeletedDate]" --output text
hunt "VPCs tagged $PROJECT" 'free, but blocks reuse' \
  aws ec2 describe-vpcs --filters "Name=tag:Project,Values=$PROJECT" \
    --query 'Vpcs[].[VpcId,CidrBlock]' --output text
hunt "Security groups tagged $PROJECT" 'free' \
  aws ec2 describe-security-groups --filters "Name=tag:Project,Values=$PROJECT" \
    --query 'SecurityGroups[].[GroupId,GroupName]' --output text
hunt "Network interfaces tagged $PROJECT" 'blocks deletions' \
  aws ec2 describe-network-interfaces --filters "Name=tag:Project,Values=$PROJECT" \
    --query 'NetworkInterfaces[].[NetworkInterfaceId,Status]' --output text

echo
echo "==========================================================================="
if [ "$FOUND" -eq 0 ]; then
  echo "  CLEAN - nothing left behind."
else
  echo "  $FOUND category/categories still have resources. Each block above shows"
  echo "  the ids. Nothing here deletes anything - that is on purpose, because a"
  echo "  data-volume snapshot may be the only copy of your in-flight data."
fi
echo
echo "  Confirm the bill actually dropped (data lags up to 24h):"
echo "    Console -> Cost Explorer -> daily granularity -> filter by service"
echo "  Watch: EC2-Other (NAT + EBS), Elastic Load Balancing, Secrets Manager."
echo "==========================================================================="
