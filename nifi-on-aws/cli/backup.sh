#!/usr/bin/env bash
# ===========================================================================
# Take a real backup BEFORE you destroy anything.
#
# Two halves, and you need both:
#   1. The FLOWS - portable JSON. Survives version changes. Do this via the API.
#   2. The DATA VOLUMES - EBS snapshots. The only way to recover in-flight data.
#
# Plus the sensitive-props key, without which half of #1 is undecryptable.
# ===========================================================================
source "$(dirname "$0")/lib/common.sh"

STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$STATE_DIR/backup-$STAMP"
mkdir -p "$OUT"

info "1/4  The sensitive properties key"
aws secretsmanager get-secret-value --secret-id "$PROJECT/sensitive-props-key" \
  --query SecretString --output text > "$OUT/sensitive-props-key.txt" 2>/dev/null \
  && { chmod 600 "$OUT/sensitive-props-key.txt"; ok "saved (KEEP THIS - flows are undecryptable without it)"; } \
  || warn "could not read the key"

info "2/4  Flow definitions via the REST API"
if is_cluster && have ALB_DNS; then
  URL="https://${NIFI_HOSTNAME:-$ALB_DNS}"
else
  URL="https://localhost:8443"
  warn "single-node mode: start an SSM port-forward first, or this will fail"
fi
PW=$(aws secretsmanager get-secret-value --secret-id "$PROJECT/nifi-admin" \
      --query SecretString --output text 2>/dev/null | jq -r .password || echo "")
if [ -n "$PW" ]; then
  ( cd "$(dirname "$0")/../migration" && \
    NIFI_URL="$URL" NIFI_USER=admin NIFI_PASSWORD="$PW" ./export-everything.sh "$OUT/flows" ) \
    && ok "flows exported" || warn "flow export failed - is the UI reachable from here?"
else
  warn "no admin password available; skipping flow export"
fi

info "3/4  EBS snapshots of every data volume"
VOLS=$(aws ec2 describe-volumes \
  --filters "Name=tag:Project,Values=$PROJECT" \
  --query 'Volumes[?Size>`50`].[VolumeId,Attachments[0].InstanceId]' --output text)
if [ -z "$VOLS" ]; then
  warn "no tagged data volumes found"
else
  echo "$VOLS" | while read -r vol inst; do
    [ -z "$vol" ] && continue
    SNAP=$(aws ec2 create-snapshot --volume-id "$vol" \
      --description "$PROJECT NiFi data volume $vol from $inst at $STAMP" \
      --tag-specifications "$(tagspec snapshot "$PROJECT-snap-$STAMP")" \
      --query SnapshotId --output text)
    ok "$vol -> $SNAP"
    echo "$SNAP $vol $inst" >> "$OUT/snapshots.txt"
  done
  warn "Snapshots complete asynchronously. Confirm before destroying:"
  warn "  aws ec2 describe-snapshots --owner-ids self --filters Name=tag:Project,Values=$PROJECT \\"
  warn "    --query 'Snapshots[].[SnapshotId,State,Progress]' --output table"
fi

info "4/4  Config files off one node"
eval "id=\${NIFI_INSTANCE_1:-}"
if [ -n "$id" ]; then
  CMD=$(aws ssm send-command --instance-ids "$id" --document-name AWS-RunShellScript \
    --parameters 'commands=["cat /data/nifi/conf/nifi.properties | grep -v sensitive.props.key"]' \
    --query 'Command.CommandId' --output text 2>/dev/null) || true
  sleep 6
  aws ssm get-command-invocation --command-id "$CMD" --instance-id "$id" \
    --query StandardOutputContent --output text > "$OUT/nifi.properties.redacted" 2>/dev/null \
    && ok "nifi.properties saved (key redacted)" || warn "could not fetch config"
fi

cp "$IDS" "$OUT/ids.env" 2>/dev/null || true
echo
ok "Backup at: $OUT"
du -sh "$OUT" | sed 's/^/    /'
warn "This folder contains the sensitive key. Move it somewhere private."
