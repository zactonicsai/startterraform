#!/usr/bin/env bash
# Stop NiFi. Without --wipe your flows and data survive.
set -euo pipefail
COMPOSE="docker compose"; docker compose version >/dev/null 2>&1 || COMPOSE="docker-compose"

if [ "${1:-}" = "--wipe" ]; then
  cat <<'TXT'

  This deletes:
    - every flow you built
    - every file still in flight inside NiFi
    - the whole provenance history
    - the sensitive-properties key, so any exported flow with encrypted
      values in it becomes undecryptable

TXT
  read -r -p "  Type WIPE to confirm: " a
  [ "$a" = "WIPE" ] || { echo "  cancelled"; exit 1; }
  $COMPOSE down -v
  rm -rf data
  echo "  everything removed"
else
  $COMPOSE down
  echo "  stopped. Data kept in ./data - './run.sh' picks up where you left off."
fi
