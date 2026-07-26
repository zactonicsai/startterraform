#!/usr/bin/env bash
# Shared helpers for all deploy/destroy scripts.
# Sourced, not executed.

set -euo pipefail

# Resolve paths relative to the repo root, wherever we're invoked from
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STATE_DIR="$SCRIPT_DIR/state"
STATE_FILE="$STATE_DIR/ids.env"
TEMPLATE_DIR="$REPO_ROOT/templates"

mkdir -p "$STATE_DIR"
touch "$STATE_FILE"

# ---- pretty output ----
if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GRN=$'\033[32m'
  C_YEL=$'\033[33m';  C_BLU=$'\033[34m'; C_BOLD=$'\033[1m'
else
  C_RESET=''; C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_BOLD=''
fi

step()  { printf '\n%s==> %s%s\n' "$C_BOLD$C_BLU" "$*" "$C_RESET"; }
ok()    { printf '%s  [ok]%s %s\n'   "$C_GRN" "$C_RESET" "$*"; }
warn()  { printf '%s  [warn]%s %s\n' "$C_YEL" "$C_RESET" "$*"; }
die()   { printf '%s  [FAIL]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }
info()  { printf '        %s\n' "$*"; }

# ---- config ----
load_config() {
  local cfg="$REPO_ROOT/config.env"
  [ -f "$cfg" ] || die "config.env not found. Copy config.env.example to config.env and edit it."
  # shellcheck disable=SC1090
  set -a; . "$cfg"; set +a
  export AWS_DEFAULT_REGION="$AWS_REGION"
  : "${PROJECT:?PROJECT must be set in config.env}"
  : "${AWS_REGION:?AWS_REGION must be set in config.env}"
}

# ---- state ----
load_state() {
  # shellcheck disable=SC1090
  set -a; . "$STATE_FILE"; set +a
}

# save NAME VALUE  -> export it and persist it to state/ids.env (idempotent)
save() {
  local k="$1" v="$2"
  # remove any previous entry for this key
  if [ -s "$STATE_FILE" ]; then
    grep -v "^export ${k}=" "$STATE_FILE" > "$STATE_FILE.tmp" || true
    mv "$STATE_FILE.tmp" "$STATE_FILE"
  fi
  printf 'export %s="%s"\n' "$k" "$v" >> "$STATE_FILE"
  export "$k=$v"
  ok "$k = $v"
}

# already_done KEY -> returns 0 if that key has a non-empty value in state
already_done() {
  local k="$1"
  load_state
  local v="${!k:-}"
  [ -n "$v" ]
}

require_state() {
  load_state
  for k in "$@"; do
    [ -n "${!k:-}" ] || die "Missing state value '$k'. Run the earlier numbered scripts first."
  done
}

# ---- misc ----
gen_password() {
  # 24 chars, alphanumeric only -- avoids quoting problems in shell/JSON/JDBC
  LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24
}

confirm() {
  local prompt="$1" expected="${2:-yes}" answer
  printf '%s%s%s ' "$C_YEL$C_BOLD" "$prompt" "$C_RESET"
  read -r answer
  [ "$answer" = "$expected" ] || die "Aborted by user."
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command '$1' not found in PATH."
}
