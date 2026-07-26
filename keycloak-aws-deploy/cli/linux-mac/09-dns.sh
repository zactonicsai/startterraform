#!/usr/bin/env bash
# Creates a Route 53 alias record pointing DOMAIN_NAME at the ALB.
. "$(dirname "$0")/lib/common.sh"
load_config
require_state ALB_DNS ALB_ZONE

if [ -z "${ROUTE53_ZONE_NAME:-}" ]; then
  warn "ROUTE53_ZONE_NAME is blank - skipping DNS."
  info "Point $DOMAIN_NAME at $ALB_DNS yourself (CNAME or ALIAS)."
  exit 0
fi

step "Looking up the hosted zone for $ROUTE53_ZONE_NAME"
ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "$ROUTE53_ZONE_NAME" \
  --query "HostedZones[?Name=='${ROUTE53_ZONE_NAME}.'].Id | [0]" --output text \
  | sed 's|/hostedzone/||')
[ -n "$ZONE_ID" ] && [ "$ZONE_ID" != "None" ] || die "Hosted zone '$ROUTE53_ZONE_NAME' not found."
save HOSTED_ZONE_ID "$ZONE_ID"

step "Creating an A/ALIAS record: $DOMAIN_NAME -> $ALB_DNS"
info "ALIAS (not CNAME): free to query, works at the zone apex, tracks the ALB's changing IPs"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/dns.json" << JSON
{
  "Comment": "Keycloak ALB alias for ${PROJECT}",
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "${DOMAIN_NAME}",
      "Type": "A",
      "AliasTarget": {
        "HostedZoneId": "${ALB_ZONE}",
        "DNSName": "${ALB_DNS}",
        "EvaluateTargetHealth": true
      }
    }
  }]
}
JSON
CHANGE=$(aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" \
  --change-batch "file://$TMP/dns.json" --query 'ChangeInfo.Id' --output text)
save DNS_RECORD_CREATED "yes"
ok "Change submitted: $CHANGE"

step "Waiting for the change to propagate across Route 53"
aws route53 wait resource-record-sets-changed --id "$CHANGE"
ok "DNS live"

printf '\n%sDNS ready. Next: ./10-verify.sh%s\n\n' "$C_GRN$C_BOLD" "$C_RESET"
