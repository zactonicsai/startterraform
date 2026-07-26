#!/usr/bin/env bash
# ===========================================================================
#  Export EVERYTHING from a running NiFi into a dated folder.
#
#  Why you want this before any migration, upgrade or teardown:
#
#    A NiFi flow lives in conf/flow.json.gz, which is a single compressed
#    blob. It is not reviewable, not diffable, and not portable between
#    versions. What IS portable is a "flow definition" - the JSON you get
#    from Download on a process group. This script pulls one for every
#    process group, plus everything around the flow that people forget:
#    parameter contexts, controller services, reporting tasks, registry
#    clients and the config files.
#
#  Usage:
#     NIFI_URL=https://nifi.example.com \
#     NIFI_USER=admin NIFI_PASSWORD=... ./export-everything.sh [outdir]
# ===========================================================================
set -euo pipefail
cd "$(dirname "$0")"
source ./nifi-api.sh

need curl; need jq

OUT="${1:-exports/$(date +%Y-%m-%d_%H%M%S)}"
mkdir -p "$OUT"/{flows,config,metadata}

info "Exporting from $NIFI_URL"
nifi_login
VERSION=$(nifi_version)
ok "NiFi version: $VERSION"

# ---------------------------------------------------------------------------
info "Recording what this instance is"
nifi_get /nifi-api/system-diagnostics > "$OUT/metadata/system-diagnostics.json" 2>/dev/null \
  && ok "system-diagnostics.json" || warn "could not read system diagnostics"

if [ "$(nifi_code /nifi-api/controller/cluster)" = "200" ]; then
  nifi_get /nifi-api/controller/cluster > "$OUT/metadata/cluster.json"
  NODES=$(jq -r '.cluster.nodes | length' "$OUT/metadata/cluster.json" 2>/dev/null || echo '?')
  ok "clustered: $NODES node(s)"
else
  ok "standalone (not clustered)"
fi

# ---------------------------------------------------------------------------
info "Walking the process group tree"
ROOT=$(nifi_get /nifi-api/flow/process-groups/root | jq -r '.processGroupFlow.id')
[ -n "$ROOT" ] && [ "$ROOT" != "null" ] || die "could not read the root process group - is the token valid?"
ok "root process group: $ROOT"

# Recursively collect every process group id and its path.
declare -a PG_IDS=() PG_PATHS=()
walk() {                       # walk <id> <path>
  local id="$1" path="$2" json
  PG_IDS+=("$id"); PG_PATHS+=("$path")
  json=$(nifi_get "/nifi-api/flow/process-groups/$id" 2>/dev/null) || return 0
  local n; n=$(echo "$json" | jq '.processGroupFlow.flow.processGroups | length' 2>/dev/null || echo 0)
  for i in $(seq 0 $((n-1))); do
    [ "$n" -eq 0 ] && break
    local cid cname
    cid=$(echo "$json"  | jq -r ".processGroupFlow.flow.processGroups[$i].id")
    cname=$(echo "$json"| jq -r ".processGroupFlow.flow.processGroups[$i].component.name")
    walk "$cid" "$path/$cname"
  done
}
walk "$ROOT" "root"
ok "found ${#PG_IDS[@]} process group(s)"

# ---------------------------------------------------------------------------
info "Downloading a flow definition for each process group"
# The download path has moved between NiFi versions. Probe both rather than
# guessing, and say which one worked so you can trust the result.
DL_TEMPLATE=""
for candidate in \
  "/nifi-api/process-groups/%s/download?includeReferencedServices=true" \
  "/nifi-api/process-groups/%s/download" \
  "/nifi-api/flow/process-groups/%s/download"
do
  probe=$(printf "$candidate" "$ROOT")
  if [ "$(nifi_code "$probe")" = "200" ]; then DL_TEMPLATE="$candidate"; break; fi
done

if [ -z "$DL_TEMPLATE" ]; then
  warn "No working download endpoint found on this version."
  warn "Find it yourself: open the UI, press F12 -> Network, right-click a"
  warn "process group -> Download flow definition, and read the request URL."
else
  ok "using ${DL_TEMPLATE%%\?*}"
  count=0
  for i in "${!PG_IDS[@]}"; do
    id="${PG_IDS[$i]}"
    safe=$(echo "${PG_PATHS[$i]}" | tr '/ ' '__' | tr -cd '[:alnum:]_.-')
    if nifi_save "$(printf "$DL_TEMPLATE" "$id")" "$OUT/flows/${safe}__${id}.json"; then
      count=$((count+1))
    else
      warn "could not download ${PG_PATHS[$i]}"
    fi
  done
  ok "$count flow definition(s) written to $OUT/flows/"
fi

# ---------------------------------------------------------------------------
info "Exporting everything AROUND the flow"
# These are the things people forget, then spend a day rebuilding by hand.
declare -A EXTRAS=(
  ["parameter-contexts.json"]="/nifi-api/flow/parameter-contexts"
  ["controller-services-root.json"]="/nifi-api/flow/process-groups/root/controller-services"
  ["reporting-tasks.json"]="/nifi-api/flow/reporting-tasks"
  ["registry-clients.json"]="/nifi-api/controller/registry-clients"
  ["controller-config.json"]="/nifi-api/controller/config"
  ["parameter-providers.json"]="/nifi-api/flow/parameter-providers"
)
for name in "${!EXTRAS[@]}"; do
  if nifi_save "${EXTRAS[$name]}" "$OUT/config/$name"; then ok "$name"
  else warn "$name unavailable on this version"; fi
done

# ---------------------------------------------------------------------------
# Templates only exist in NiFi 1.x. They are REMOVED in 2.x, so if this
# instance has any, they must be converted before you upgrade.
info "Checking for legacy XML templates (1.x only)"
if [ "$(nifi_code /nifi-api/flow/templates)" = "200" ]; then
  nifi_get /nifi-api/flow/templates > "$OUT/metadata/templates-list.json"
  T=$(jq '.templates | length' "$OUT/metadata/templates-list.json" 2>/dev/null || echo 0)
  if [ "${T:-0}" -gt 0 ]; then
    mkdir -p "$OUT/templates-legacy"
    warn "$T template(s) found. Templates DO NOT EXIST in NiFi 2.x."
    warn "Downloading them, but you must convert each one - see MIGRATION.md."
    for tid in $(jq -r '.templates[].id' "$OUT/metadata/templates-list.json"); do
      nifi_save "/nifi-api/templates/$tid/download" "$OUT/templates-legacy/$tid.xml" \
        && ok "template $tid" || warn "template $tid failed"
    done
  else
    ok "no templates - nothing to convert"
  fi
else
  ok "no template API (expected on NiFi 2.x)"
fi

# ---------------------------------------------------------------------------
info "Copying config files out of the container (if running locally)"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx nifi; then
  for f in nifi.properties authorizers.xml bootstrap.conf state-management.xml \
           logback.xml login-identity-providers.xml flow.json.gz; do
    docker cp "nifi:/opt/nifi/nifi-current/conf/$f" "$OUT/config/$f" 2>/dev/null \
      && ok "conf/$f" || true
  done
  warn "nifi.properties contains the sensitive-props key. Treat this folder as a secret."
else
  warn "No local 'nifi' container. On EC2, fetch these with:"
  warn "  aws ssm start-session --target <instance-id>"
  warn "  sudo docker cp nifi:/opt/nifi/nifi-current/conf ./conf-backup"
fi

# ---------------------------------------------------------------------------
cat > "$OUT/MANIFEST.md" << MD
# NiFi export

- **Source:** $NIFI_URL
- **NiFi version:** $VERSION
- **Taken:** $(date -u +"%Y-%m-%dT%H:%M:%SZ")
- **Process groups:** ${#PG_IDS[@]}

## Layout

| Path | What it is |
|---|---|
| \`flows/\` | One portable flow definition (JSON) per process group. **This is the part that moves between versions.** |
| \`config/\` | Parameter contexts, controller services, reporting tasks, registry clients, and the raw conf files. |
| \`metadata/\` | Version, cluster membership, diagnostics. Context for whoever reads this later. |
| \`templates-legacy/\` | Only present if this was NiFi 1.x. Templates do not exist in 2.x and must be converted. |

## Restore

\`\`\`bash
NIFI_URL=https://new-nifi.example.com ./import-flows.sh $OUT
\`\`\`

## Warning

\`config/nifi.properties\` contains \`nifi.sensitive.props.key\`. Anything
encrypted inside a flow definition can only be decrypted with that key.
Store this folder somewhere private, and keep the key even if you throw the
rest away.
MD

info "Done"
ok "export written to: $OUT"
du -sh "$OUT" 2>/dev/null | sed 's/^/    /'
