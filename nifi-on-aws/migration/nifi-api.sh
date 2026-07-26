#!/usr/bin/env bash
# ===========================================================================
#  Shared helpers for talking to the NiFi REST API.
#  Source this, do not run it:   source ./nifi-api.sh
#
#  Everything the NiFi UI does, it does through this same API. That is the
#  single most useful fact for both automation and debugging: if you cannot
#  work out which endpoint to call, open the UI in your browser, press F12,
#  do the thing by hand, and read the request in the Network tab.
# ===========================================================================

NIFI_URL="${NIFI_URL:-https://localhost:8443}"
NIFI_USER="${NIFI_USER:-admin}"
NIFI_PASSWORD="${NIFI_PASSWORD:-ChangeThisLocally123}"
# -k skips certificate verification. Correct for a self-signed local cert,
# WRONG against production - set NIFI_INSECURE=0 once you have a real cert.
NIFI_INSECURE="${NIFI_INSECURE:-1}"

_CURL_OPTS=(-sS --max-time 60)
[ "$NIFI_INSECURE" = "1" ] && _CURL_OPTS+=(-k)

info() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '    \033[0;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '    \033[0;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '    \033[0;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null || die "$1 is required but not installed"; }

NIFI_TOKEN=""

# ---------------------------------------------------------------------------
# nifi_login - get a bearer token.
#
# With Single User auth this exchanges username+password for a JWT.
# With OIDC or client certificates there is no password to exchange, so this
# step is skipped and you authenticate differently - see the guide, Chapter 13.
# ---------------------------------------------------------------------------
nifi_login() {
  local body
  body=$(curl "${_CURL_OPTS[@]}" -X POST \
      "$NIFI_URL/nifi-api/access/token" \
      --data-urlencode "username=$NIFI_USER" \
      --data-urlencode "password=$NIFI_PASSWORD" \
      -w '\n%{http_code}') || die "cannot reach $NIFI_URL"

  local code="${body##*$'\n'}"
  local token="${body%$'\n'*}"

  if [ "$code" = "201" ] || [ "$code" = "200" ]; then
    NIFI_TOKEN="$token"
    ok "authenticated as $NIFI_USER"
    return 0
  fi

  # Anonymous / mTLS / OIDC instances legitimately refuse this endpoint.
  warn "token endpoint returned HTTP $code - continuing without a token."
  warn "  (normal for OIDC or certificate-based NiFi; fatal for single-user auth)"
  NIFI_TOKEN=""
}

# nifi_get <path> [extra curl args...]  -> body on stdout
nifi_get() {
  local path="$1"; shift || true
  local -a auth=()
  [ -n "$NIFI_TOKEN" ] && auth=(-H "Authorization: Bearer $NIFI_TOKEN")
  curl "${_CURL_OPTS[@]}" "${auth[@]}" "$@" "$NIFI_URL$path"
}

# nifi_code <path> -> HTTP status only. Used to probe which endpoints exist.
nifi_code() {
  local path="$1"
  local -a auth=()
  [ -n "$NIFI_TOKEN" ] && auth=(-H "Authorization: Bearer $NIFI_TOKEN")
  curl "${_CURL_OPTS[@]}" "${auth[@]}" -o /dev/null -w '%{http_code}' "$NIFI_URL$path"
}

# nifi_save <path> <outfile> -> download to a file, report success
nifi_save() {
  local path="$1" out="$2"
  local -a auth=()
  [ -n "$NIFI_TOKEN" ] && auth=(-H "Authorization: Bearer $NIFI_TOKEN")
  local code
  code=$(curl "${_CURL_OPTS[@]}" "${auth[@]}" -o "$out" -w '%{http_code}' "$NIFI_URL$path")
  if [ "$code" = "200" ] && [ -s "$out" ]; then return 0; fi
  rm -f "$out"; return 1
}

nifi_version() {
  nifi_get /nifi-api/system-diagnostics 2>/dev/null \
    | jq -r '.systemDiagnostics.aggregateSnapshot.versionInfo.niFiVersion // "unknown"' 2>/dev/null \
    || echo unknown
}
