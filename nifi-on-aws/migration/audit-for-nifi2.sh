#!/usr/bin/env bash
# ===========================================================================
#  PRE-MIGRATION AUDIT: will these flows survive the jump to NiFi 2.x?
#
#  Run this against a NiFi 1.x instance BEFORE you build anything new.
#  It looks for the five things that break, in rough order of how much pain
#  each one causes:
#
#    1. XML templates          - REMOVED in 2.x, no automatic conversion
#    2. Variables / Variable Registry - REMOVED, replaced by Parameter Contexts
#    3. Deprecated processors  - deleted, become "ghost components"
#    4. Event Driven scheduling - removed, must become Time Driven
#    5. Scripted components in ECMAScript / Lua / Ruby / Jython - removed
#
#  Usage:
#    ./audit-for-nifi2.sh                     # audit a live instance
#    ./audit-for-nifi2.sh --flow flow.xml.gz  # audit an exported flow file
# ===========================================================================
set -euo pipefail
cd "$(dirname "$0")"
source ./nifi-api.sh
need jq

FINDINGS=0
CRITICAL=0
report()   { printf '    %s\n' "$*"; }
finding()  { FINDINGS=$((FINDINGS+1)); printf '    \033[0;33m[FIX]\033[0m %s\n' "$*"; }
critical() { CRITICAL=$((CRITICAL+1)); FINDINGS=$((FINDINGS+1)); printf '    \033[0;31m[BLOCKER]\033[0m %s\n' "$*"; }

# Processors and features removed in NiFi 2.x. Not exhaustive - the authority
# is the official "Migrating Deprecated Components and Features" wiki page -
# but these are the ones that show up in real 1.x flows most often.
REMOVED_PROCESSORS=(
  GetHTTP PostHTTP                       # -> InvokeHTTP
  GetFTP GetSFTP                         # -> ListFTP/FetchFTP, ListSFTP/FetchSFTP
  PutS3Object_v1 ListS3_v1
  GetAzureQueueStorage PutAzureQueueStorage   # -> the _v12 variants
  GetSolr PutSolrContentStream
  RethinkDB
  ExecuteScript:ECMAScript ExecuteScript:lua ExecuteScript:ruby ExecuteScript:python
  ConsumeKafka_0_10 PublishKafka_0_10
  ConsumeKafka_1_0 PublishKafka_1_0
  ConsumeKafka_2_0 PublishKafka_2_0      # -> ConsumeKafka / PublishKafka
  PutHiveQL SelectHiveQL PutHiveStreaming
  JoltTransformJSON                      # relocated: bundle coordinates changed
  ListenSMTP
  Base64EncodeContent
  DistributeLoad
)

audit_live() {
  info "Auditing live instance: $NIFI_URL"
  nifi_login
  local v; v=$(nifi_version)
  report "NiFi version reported: $v"
  case "$v" in
    1.*) report "This is a 1.x instance - the audit applies." ;;
    2.*) report "Already on 2.x. Audit is mostly moot; checking anyway." ;;
    *)   warn "Could not determine version." ;;
  esac

  # ---- 1. Templates ----
  info "1/6  XML templates"
  if [ "$(nifi_code /nifi-api/flow/templates)" = "200" ]; then
    local n; n=$(nifi_get /nifi-api/flow/templates | jq '.templates | length')
    if [ "${n:-0}" -gt 0 ]; then
      critical "$n XML template(s). Templates DO NOT EXIST in NiFi 2.x."
      report   "        Fix, while still on 1.x: drag each template onto the canvas,"
      report   "        then right-click the resulting process group -> Download flow"
      report   "        definition. That JSON is what imports into 2.x."
    else
      report "none - good"
    fi
  else
    report "template API absent (this is 2.x behaviour)"
  fi

  # ---- 2. Variables ----
  info "2/6  Variables / Variable Registry"
  local root; root=$(nifi_get /nifi-api/flow/process-groups/root | jq -r '.processGroupFlow.id')
  local vcount=0
  if [ "$(nifi_code "/nifi-api/process-groups/$root/variable-registry")" = "200" ]; then
    vcount=$(nifi_get "/nifi-api/process-groups/$root/variable-registry" \
             | jq '.variableRegistry.variables | length' 2>/dev/null || echo 0)
  fi
  if [ "${vcount:-0}" -gt 0 ]; then
    critical "$vcount variable(s) on the root group. Variables are REMOVED in 2.x."
    report   "        Fix: recreate them as Parameter Contexts, then change every"
    report   "        \${var} reference to #{param}. Expression Language syntax differs."
  else
    report "none on the root group (check child groups in the UI too)"
  fi

  # ---- 3. Deprecated processors, via the deprecation log ----
  info "3/6  Deprecated components"
  report "NiFi 1.x writes a dedicated log for exactly this question:"
  report "    logs/nifi-deprecation.log"
  report "That file is the authoritative list for YOUR flows. Read it:"
  report "    docker exec nifi tail -100 /opt/nifi/nifi-current/logs/nifi-deprecation.log"
  finding "Read nifi-deprecation.log and resolve every distinct component named in it."

  # ---- 4/5/6 need the flow file ----
  info "4/6  Event Driven scheduling, scripted languages, bundle moves"
  report "These need the flow file itself. Export it and re-run with --flow:"
  report "    docker cp nifi:/opt/nifi/nifi-current/conf/flow.xml.gz ."
  report "    ./audit-for-nifi2.sh --flow flow.xml.gz"
}

audit_flow_file() {
  local f="$1"
  info "Auditing flow file: $f"
  [ -f "$f" ] || die "no such file: $f"

  local text
  case "$f" in
    *.gz)   text=$(gunzip -c "$f") ;;
    *)      text=$(cat "$f") ;;
  esac
  local size; size=$(printf '%s' "$text" | wc -c)
  report "decompressed size: $size bytes"

  case "$f" in
    *flow.xml*) report "flow.xml.gz -> this is a NiFi 1.x flow." ;;
    *flow.json*) report "flow.json.gz -> 1.10+ format." ;;
  esac

  info "Removed or relocated processors referenced by this flow"
  local hits=0
  for p in "${REMOVED_PROCESSORS[@]}"; do
    local name="${p%%:*}"
    local c; c=$(printf '%s' "$text" | grep -o "$name" | wc -l | tr -d ' ')
    if [ "$c" -gt 0 ]; then
      finding "$name  (referenced ~$c time(s))"
      hits=$((hits+1))
    fi
  done
  [ "$hits" -eq 0 ] && report "none of the commonly-removed processors found"

  info "Event Driven scheduling"
  local ed; ed=$(printf '%s' "$text" | grep -o 'EVENT_DRIVEN' | wc -l | tr -d ' ')
  if [ "$ed" -gt 0 ]; then
    critical "$ed component(s) use EVENT_DRIVEN scheduling, removed in 2.x."
    report   "        Fix: switch each to Time Driven before upgrading."
  else
    report "none - good"
  fi

  info "Scripted components in removed languages"
  for lang in ECMAScript lua ruby python jython; do
    local c; c=$(printf '%s' "$text" | grep -oi "$lang" | wc -l | tr -d ' ')
    [ "$c" -gt 0 ] && finding "possible '$lang' scripting (~$c match(es)) - only Groovy survives, or use the new Python API"
  done

  info "Variables used in Expression Language"
  local vr; vr=$(printf '%s' "$text" | grep -o 'VARIABLE_REGISTRY' | wc -l | tr -d ' ')
  [ "$vr" -gt 0 ] && critical "$vr reference(s) to VARIABLE_REGISTRY scope, removed in 2.x."
}

MODE=live; FLOW=""
while [ $# -gt 0 ]; do
  case "$1" in
    --flow) MODE=file; FLOW="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

echo "==========================================================================="
echo "  NiFi 1.x -> 2.x pre-migration audit"
echo "==========================================================================="
if [ "$MODE" = file ]; then audit_flow_file "$FLOW"; else audit_live; fi

echo
echo "==========================================================================="
printf "  %d finding(s), of which %d are blockers.\n" "$FINDINGS" "$CRITICAL"
echo
echo "  Remember the two rules that catch everyone:"
echo
echo "  1. Upgrade to NiFi 1.27.0 or later FIRST, then to 2.x."
echo "     Jumping straight from an old 1.x to 2.x is not a supported path."
echo
echo "  2. Copy nifi.sensitive.props.key to the new cluster BEFORE importing"
echo "     anything. Without the original key, every encrypted password inside"
echo "     your flows is unrecoverable and must be retyped."
echo "==========================================================================="
[ "$CRITICAL" -gt 0 ] && exit 2 || exit 0
