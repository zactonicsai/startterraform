#!/usr/bin/env bash
# ===========================================================================
#  DESTROY EVERYTHING - deliberately slow and full of questions.
#
#  Order matters and roughly reverses creation, because nearly everything
#  holds a reference to something made before it.
#
#  THE NIFI-SPECIFIC TRAP: the data volumes were created with
#  DeleteOnTermination=false ON PURPOSE, so they survive an instance being
#  replaced. That means terminating instances does NOT remove them, and they
#  keep billing silently. This script asks you what to do with them.
# ===========================================================================
source "$(dirname "$0")/lib/common.sh"

cat <<TXT

===========================================================================
  About to destroy the '$PROJECT' deployment in $AWS_REGION.

  This removes: load balancer, listener, target group, NiFi instances,
  ZooKeeper, NAT Gateway(s), Elastic IPs, route tables, subnets, the VPC,
  security groups, the IAM role and profile, and the log group.

  Secrets are SCHEDULED for deletion (7-day recovery window), not erased.
  Data volumes are handled separately - you will be asked.
===========================================================================
TXT
read -r -p "  Type the project name to continue: " a
[ "$a" = "$PROJECT" ] || { echo "  cancelled"; exit 1; }
read -r -p "  Type DESTROY to confirm: " a
[ "$a" = "DESTROY" ] || { echo "  cancelled"; exit 1; }

echo
warn "Have you run ./backup.sh? Flows and in-flight data are about to go."
read -r -p "  Type yes if you have a backup you trust: " a
[ "$a" = yes ] || { echo "  cancelled - run ./backup.sh first"; exit 1; }

echo
echo "  What should happen to the NiFi DATA VOLUMES?"
echo "    snapshot  - snapshot each, then delete the volumes  (recommended)"
echo "    delete    - delete them now, no snapshot             (irreversible)"
echo "    keep      - leave them attached-less and billing     (you clean up later)"
read -r -p "  Choice [snapshot/delete/keep]: " VOLPLAN
case "$VOLPLAN" in snapshot|delete|keep) ;; *) die "unrecognised choice"; esac

gone() { printf '    \033[0;32m[gone]\033[0m %s\n' "$*"; }
miss() { printf '    \033[0;90m[n/a]\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------------------
info "1. Listener"
if have LISTENER_ARN; then
  aws elbv2 delete-listener --listener-arn "$LISTENER_ARN" 2>/dev/null && gone "listener" || miss "listener"
else miss "no listener recorded"; fi

info "2. Load balancer"
if have ALB_ARN; then
  aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" 2>/dev/null && gone "ALB" || miss "ALB"
  # An ALB leaves network interfaces behind for a while. Deleting its security
  # group or subnets too soon fails with DependencyViolation. This wait is the
  # single most common reason a teardown "randomly" fails.
  info "   waiting 90s for ALB network interfaces to release"
  sleep 90
else miss "no ALB recorded"; fi

info "3. Target group"
if have TG_ARN; then
  aws elbv2 delete-target-group --target-group-arn "$TG_ARN" 2>/dev/null && gone "target group" || miss "target group"
fi

# ---------------------------------------------------------------------------
info "4. Data volumes - recording them BEFORE the instances go"
DATA_VOLS=$(aws ec2 describe-volumes \
  --filters "Name=tag:Project,Values=$PROJECT" \
  --query "Volumes[?Size>=\`$DATA_VOLUME_GB\`].VolumeId" --output text || echo "")
if [ -n "$DATA_VOLS" ]; then
  ok "found: $DATA_VOLS"
  if [ "$VOLPLAN" = snapshot ]; then
    for v in $DATA_VOLS; do
      S=$(aws ec2 create-snapshot --volume-id "$v" \
        --description "$PROJECT final snapshot before destroy" \
        --tag-specifications "$(tagspec snapshot "$PROJECT-final")" \
        --query SnapshotId --output text)
      ok "snapshot $v -> $S"
    done
    info "   waiting for snapshots to complete (can take several minutes)"
    for v in $DATA_VOLS; do
      aws ec2 wait snapshot-completed --filters "Name=volume-id,Values=$v" 2>/dev/null \
        && ok "$v snapshot done" || warn "$v snapshot wait timed out - CHECK BEFORE DELETING"
    done
  fi
else
  miss "no tagged data volumes found"
fi

# ---------------------------------------------------------------------------
info "5. Terminating instances"
INST=$(aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=$PROJECT" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text)
if [ -n "$INST" ]; then
  aws ec2 terminate-instances --instance-ids $INST >/dev/null
  gone "requested termination: $INST"
  info "   waiting for them to terminate"
  aws ec2 wait instance-terminated --instance-ids $INST && ok "all terminated"
else miss "no instances"; fi

info "6. Data volumes - now detached"
if [ -n "$DATA_VOLS" ]; then
  case "$VOLPLAN" in
    snapshot|delete)
      for v in $DATA_VOLS; do
        for _ in $(seq 1 24); do
          ST=$(aws ec2 describe-volumes --volume-ids "$v" --query 'Volumes[0].State' --output text 2>/dev/null || echo gone)
          [ "$ST" = available ] && break
          [ "$ST" = gone ] && break
          sleep 5
        done
        aws ec2 delete-volume --volume-id "$v" 2>/dev/null && gone "volume $v" || warn "could not delete $v (state: $ST)"
      done ;;
    keep)
      warn "KEEPING these volumes. They are billing you about \$$(( DATA_VOLUME_GB * 8 / 100 ))/month each:"
      for v in $DATA_VOLS; do warn "    $v"; done
      warn "Delete later with: aws ec2 delete-volume --volume-id <id>" ;;
  esac
fi

# ---------------------------------------------------------------------------
info "7. NAT Gateways"
for n in "${NAT_A:-}" "${NAT_B:-}"; do
  [ -z "$n" ] && continue
  aws ec2 delete-nat-gateway --nat-gateway-id "$n" >/dev/null 2>&1 && gone "NAT $n" || miss "NAT $n"
done
if [ -n "${NAT_A:-}" ]; then
  info "   waiting for NAT deletion (needed before the subnets can go)"
  for n in "${NAT_A:-}" "${NAT_B:-}"; do
    [ -z "$n" ] && continue
    aws ec2 wait nat-gateway-deleted --nat-gateway-ids "$n" 2>/dev/null && ok "$n deleted" || warn "$n wait timed out"
  done
fi

info "8. Elastic IPs"
for e in "${EIP_A:-}" "${EIP_B:-}"; do
  [ -z "$e" ] && continue
  # An unassociated Elastic IP is one of the classic silent charges.
  aws ec2 release-address --allocation-id "$e" 2>/dev/null && gone "EIP $e" || miss "EIP $e"
done

info "9. Route tables and subnets"
for rt in "${PRIVATE_RT_A:-}" "${PRIVATE_RT_B:-}" "${PUBLIC_RT:-}"; do
  [ -z "$rt" ] && continue
  for assoc in $(aws ec2 describe-route-tables --route-table-ids "$rt" \
      --query 'RouteTables[0].Associations[?!Main].RouteTableAssociationId' --output text 2>/dev/null); do
    aws ec2 disassociate-route-table --association-id "$assoc" 2>/dev/null || true
  done
  aws ec2 delete-route-table --route-table-id "$rt" 2>/dev/null && gone "route table $rt" || miss "$rt"
done
for s in "${PRIVATE_SUBNET_A:-}" "${PRIVATE_SUBNET_B:-}" "${PUBLIC_SUBNET_A:-}" "${PUBLIC_SUBNET_B:-}"; do
  [ -z "$s" ] && continue
  aws ec2 delete-subnet --subnet-id "$s" 2>/dev/null && gone "subnet $s" || miss "$s"
done

info "10. Internet Gateway"
if have IGW_ID; then
  aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" 2>/dev/null || true
  aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" 2>/dev/null && gone "IGW" || miss "IGW"
fi

info "11. Security groups"
# Order matters: a group referenced by another cannot be deleted. NiFi first
# (it references ALB and ZK), then the rest. Retried because ENI release lags.
for attempt in 1 2 3; do
  for sg in "${NIFI_SG:-}" "${ZK_SG:-}" "${ALB_SG:-}"; do
    [ -z "$sg" ] && continue
    aws ec2 delete-security-group --group-id "$sg" 2>/dev/null && gone "sg $sg" || true
  done
  sleep 15
done

info "12. VPC"
if have VPC_ID; then
  aws ec2 delete-vpc --vpc-id "$VPC_ID" 2>/dev/null && gone "VPC $VPC_ID" \
    || warn "VPC still has dependencies - run ./orphan-hunt.sh"
fi

info "13. IAM"
if have IAM_PROFILE; then
  aws iam remove-role-from-instance-profile --instance-profile-name "$IAM_PROFILE" \
    --role-name "$IAM_ROLE" 2>/dev/null || true
  aws iam delete-instance-profile --instance-profile-name "$IAM_PROFILE" 2>/dev/null && gone "instance profile" || miss "profile"
fi
if have IAM_ROLE; then
  aws iam delete-role-policy --role-name "$IAM_ROLE" --policy-name "$PROJECT-node-inline" 2>/dev/null || true
  for p in AmazonSSMManagedInstanceCore CloudWatchAgentServerPolicy; do
    aws iam detach-role-policy --role-name "$IAM_ROLE" --policy-arn "arn:aws:iam::aws:policy/$p" 2>/dev/null || true
  done
  aws iam delete-role --role-name "$IAM_ROLE" 2>/dev/null && gone "role" || miss "role"
fi

info "14. Log group"
if have LOG_GROUP; then
  read -r -p "  Delete CloudWatch logs at $LOG_GROUP? [y/N] " a
  if [ "$a" = y ]; then
    aws logs delete-log-group --log-group-name "$LOG_GROUP" 2>/dev/null && gone "logs" || miss "logs"
  else
    warn "keeping logs. They bill for storage - retention is 30 days."
  fi
fi

info "15. Secrets"
echo "    Secrets are scheduled for deletion with a 7-day recovery window."
echo "    The NAME stays reserved for those 7 days, so an immediate re-deploy"
echo "    will hit 'already exists' - that is expected, not a bug."
read -r -p "  Schedule secret deletion? [y/N] " a
if [ "$a" = y ]; then
  for s in artifactory sensitive-props-key nifi-admin; do
    aws secretsmanager delete-secret --secret-id "$PROJECT/$s" \
      --recovery-window-in-days 7 >/dev/null 2>&1 && gone "$PROJECT/$s (recoverable 7d)" || miss "$PROJECT/$s"
  done
  warn "The sensitive-props-key is among these. If you kept flow exports,"
  warn "you need that key to ever decrypt them again. Saved it? Really?"
else
  warn "keeping secrets - costs about \$0.40/month each"
fi

mv "$IDS" "$IDS.destroyed-$(date +%s)" 2>/dev/null || true
echo
ok "Destroy sequence finished."
warn "NOW RUN ./orphan-hunt.sh - it finds what silently survived."
