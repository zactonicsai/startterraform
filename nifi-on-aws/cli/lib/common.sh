# ===========================================================================
#  Shared helpers. Sourced by every script; never run directly.
#
#  The design idea worth copying: every script writes the AWS ids it created
#  into state/ids.env and SKIPS work already recorded there. So every script
#  is safe to re-run, and a failure at step 6 does not mean starting over.
# ===========================================================================

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$HERE/../config.env" ] && source "$HERE/../config.env" || true
[ -f "$HERE/config.env" ] && source "$HERE/config.env" || {
  printf '\033[0;31m[fail]\033[0m No config.env found.\n  cp config.env.example config.env  and edit it.\n' >&2
  exit 1
}

STATE_DIR="${STATE_DIR:-$HERE/state}"
IDS="$STATE_DIR/ids.env"
mkdir -p "$STATE_DIR"
touch "$IDS"
# shellcheck disable=SC1090
source "$IDS"

export AWS_DEFAULT_REGION="$AWS_REGION"

info() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '    \033[0;32m[ok]\033[0m %s\n' "$*"; }
skip() { printf '    \033[0;90m[skip]\033[0m %s\n' "$*"; }
warn() { printf '    \033[0;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '    \033[0;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

# remember NAME VALUE  -> persist to ids.env and export for this shell
remember() {
  local name="$1" value="${2:-}"
  # Written as a plain if, because `[ -z "$x" ] || [ "$x" = None ] && { ...; }`
  # groups as `(A||B) && C` and returns 1 on the success path, which `set -e`
  # then treats as a fatal error. A genuine footgun.
  if [ -z "$value" ] || [ "$value" = "None" ] || [ "$value" = "null" ]; then
    warn "refusing to store empty/None value for $name"
    return 1
  fi
  sed -i.bak "/^export $name=/d" "$IDS" 2>/dev/null || true
  rm -f "$IDS.bak"
  echo "export $name=\"$value\"" >> "$IDS"
  export "$name=$value"
  return 0
}

# have NAME -> true if already recorded and non-empty
have() { [ -n "${!1:-}" ]; }

# tags for everything, so orphan-hunt.sh can find strays later
tagspec() {  # tagspec <ResourceType> <Name>
  echo "ResourceType=$1,Tags=[{Key=Name,Value=$2},{Key=Project,Value=$PROJECT},{Key=ManagedBy,Value=nifi-cli-scripts}]"
}
tags_cli() { echo "Key=Name,Value=$1 Key=Project,Value=$PROJECT Key=ManagedBy,Value=nifi-cli-scripts"; }

is_cluster() { [ "${NODE_COUNT:-1}" -gt 1 ]; }

# Wait for something, printing dots. waitfor <description> <command...>
waitfor() {
  local what="$1"; shift
  printf '    waiting for %s ' "$what"
  for _ in $(seq 1 120); do
    if "$@" >/dev/null 2>&1; then printf ' ready\n'; return 0; fi
    printf '.'; sleep 5
  done
  printf ' TIMEOUT\n'
  return 1
}
