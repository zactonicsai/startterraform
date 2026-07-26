#!/usr/bin/env bash
# Takes a manual RDS snapshot and records an inventory. Run BEFORE destroying.
. "$(dirname "$0")/lib/common.sh"
load_config; require_state DB_ID

step "Confirming account and region"
aws sts get-caller-identity --query '[Account,Arn]' --output text
info "Region: $AWS_REGION"

step "Taking a manual RDS snapshot"
info "Automated backups die with the instance. Manual snapshots survive."
SNAP="${PROJECT}-manual-$(date -u +%Y%m%d-%H%M%S)"
aws rds create-db-snapshot \
  --db-instance-identifier "$DB_ID" \
  --db-snapshot-identifier "$SNAP" \
  --tags "Key=Project,Value=${PROJECT}" "Key=Reason,Value=pre-teardown" >/dev/null
save LAST_MANUAL_SNAPSHOT "$SNAP"

info "Waiting for the snapshot to complete (5-15 minutes)..."
aws rds wait db-snapshot-available --db-snapshot-identifier "$SNAP"
ok "Snapshot available: $SNAP"

step "Recording a pre-destroy inventory"
INV="$STATE_DIR/pre-destroy-inventory.txt"
aws resourcegroupstaggingapi get-resources \
  --tag-filters "Key=Project,Values=${PROJECT}" \
  --query 'ResourceTagMappingList[].ResourceARN' --output text | tr '\t' '\n' > "$INV"
ok "$(wc -l < "$INV") tagged resources recorded in $INV"

step "Exporting the Keycloak realm config (optional second backup)"
info "A DB snapshot is opaque; a realm export is readable JSON you can diff and re-import."
ID=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text 2>/dev/null || echo None)
if [ "$ID" != "None" ] && [ -n "$ID" ]; then
  info "Run this manually if you want the export:"
  echo
  echo "    aws ssm start-session --target $ID"
  echo "    sudo docker exec keycloak /opt/keycloak/bin/kc.sh export \\"
  echo "        --dir /tmp/kc-export --users realm_file"
  echo "    sudo docker cp keycloak:/tmp/kc-export /tmp/kc-export"
  echo
else
  warn "No running instances to export from."
fi

printf '\n%sBackups done. You may now run ./destroy-all.sh%s\n\n' "$C_GRN$C_BOLD" "$C_RESET"
