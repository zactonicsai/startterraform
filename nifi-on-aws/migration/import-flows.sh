#!/usr/bin/env bash
# ===========================================================================
#  Import flow definitions (JSON) into a NiFi instance.
#
#  This is the second half of a migration. export-everything.sh produced a
#  folder of portable flow definitions; this uploads them into a new NiFi as
#  child process groups of the root.
#
#  READ THIS FIRST:
#  Set nifi.sensitive.props.key on the TARGET to the SAME value the source
#  used, before importing. Encrypted properties inside a flow definition can
#  only be decrypted with the original key. Import with the wrong key and the
#  flow arrives with every password blank and no warning that it happened.
#
#  Usage:
#    NIFI_URL=https://new-nifi:8443 ./import-flows.sh exports/2026-07-26_120000
#    ./import-flows.sh <dir> --dry-run
# ===========================================================================
set -euo pipefail
cd "$(dirname "$0")"
source ./nifi-api.sh
need curl; need jq

DIR="${1:-}"; shift || true
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1
[ -n "$DIR" ] || die "usage: $0 <export-directory> [--dry-run]"
[ -d "$DIR/flows" ] || die "$DIR/flows not found - is that an export directory?"

info "Target: $NIFI_URL"
nifi_login
ok "target NiFi version: $(nifi_version)"

ROOT=$(nifi_get /nifi-api/flow/process-groups/root | jq -r '.processGroupFlow.id')
[ -n "$ROOT" ] && [ "$ROOT" != null ] || die "cannot read root process group"
ok "root process group: $ROOT"

# The root group's own definition would import the entire canvas on top of
# itself, which is almost never what you want. Skip it by default.
mapfile -t FILES < <(find "$DIR/flows" -name '*.json' ! -name 'root__*' | sort)
info "${#FILES[@]} flow definition(s) to import (root-level export skipped)"
[ "${#FILES[@]}" -eq 0 ] && { warn "nothing to do"; exit 0; }

info "Sanity-checking the files before uploading anything"
BAD=0
for f in "${FILES[@]}"; do
  if ! jq -e '.flowContents // .flowSnapshot // .' "$f" >/dev/null 2>&1; then
    warn "not valid JSON: $(basename "$f")"; BAD=$((BAD+1)); continue
  fi
  # Warn about encrypted values, because this is where silent data loss happens.
  if grep -q 'enc{' "$f" 2>/dev/null; then
    warn "$(basename "$f") contains encrypted values - the sensitive key must match"
  fi
done
[ "$BAD" -gt 0 ] && die "$BAD file(s) unreadable; fix them before importing"
ok "all files parse"

if [ "$DRY" = 1 ]; then
  info "Dry run - would import:"
  for f in "${FILES[@]}"; do printf '      %s\n' "$(basename "$f")"; done
  exit 0
fi

# Lay the imported groups out in a grid so they do not all land on top of
# each other in the middle of the canvas.
X=0; Y=0; N=0; FAILED=0
info "Uploading"
for f in "${FILES[@]}"; do
  NAME=$(basename "$f" .json | sed 's/__[0-9a-f-]\{36\}$//')
  CLIENT_ID="import-$(date +%s)-$N"

  RESP=$(curl "${_CURL_OPTS[@]}" \
      ${NIFI_TOKEN:+-H "Authorization: Bearer $NIFI_TOKEN"} \
      -X POST \
      -F "file=@$f" \
      -F "groupName=$NAME" \
      -F "positionX=$X" \
      -F "positionY=$Y" \
      -F "clientId=$CLIENT_ID" \
      -w '\n%{http_code}' \
      "$NIFI_URL/nifi-api/process-groups/$ROOT/process-groups/upload" 2>/dev/null) || true

  CODE="${RESP##*$'\n'}"
  if [ "$CODE" = "201" ] || [ "$CODE" = "200" ]; then
    ok "$NAME"
    N=$((N+1))
  else
    warn "$NAME -> HTTP $CODE"
    printf '        %s\n' "$(echo "${RESP%$'\n'*}" | head -c 300)"
    FAILED=$((FAILED+1))
  fi

  X=$((X+450)); if [ "$X" -gt 1800 ]; then X=0; Y=$((Y+350)); fi
done

echo
info "Result: $N imported, $FAILED failed"
cat <<'TXT'

    Imported flows arrive STOPPED. That is deliberate - nothing starts
    processing data until you look at it. Before starting anything:

      1. Fix "ghost" components. A processor that no longer exists in this
         version appears greyed out with a warning. Replace it.
      2. Re-point controller services. Database and SSL context services are
         referenced by id; if they were not exported, recreate and rebind them.
      3. Check Parameter Contexts. If the source used Variables (1.x), those
         did not come across - they no longer exist.
      4. Retype any sensitive property that came in blank.
      5. Start ONE process group and watch the queues before doing the rest.
TXT
[ "$FAILED" -gt 0 ] && exit 1 || exit 0
