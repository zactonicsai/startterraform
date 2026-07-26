#!/usr/bin/env bash
# ===========================================================================
# Start NiFi locally on a Mac (works on Linux too) and wait until it is
# genuinely usable, not merely "started".
# ===========================================================================
set -euo pipefail

IMAGE="apache/nifi:2.10.0"
UI="https://localhost:8443/nifi"

info() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '    \033[0;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '    \033[0;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '    \033[0;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

info "Checking prerequisites"
command -v docker >/dev/null || die "Docker not found. Install Docker Desktop."
docker info >/dev/null 2>&1 || die "Docker is installed but not running. Start Docker Desktop."
ok "docker $(docker --version | awk '{print $3}' | tr -d ,)"

# Compose v2 is a docker subcommand; v1 was a separate binary.
if docker compose version >/dev/null 2>&1; then COMPOSE="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then COMPOSE="docker-compose"
else die "Docker Compose not found."; fi
ok "compose available"

# ---- Memory. NiFi will start with less and then behave strangely. ----
MEM_BYTES=$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)
MEM_GB=$(( MEM_BYTES / 1024 / 1024 / 1024 ))
if [ "$MEM_GB" -lt 4 ]; then
  warn "Docker has only ${MEM_GB} GB of RAM. NiFi wants 4 GB or more."
  warn "Docker Desktop -> Settings -> Resources -> Memory, then rerun."
else
  ok "Docker memory: ${MEM_GB} GB"
fi

# ---- Apple Silicon check ----
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
  info "Apple Silicon detected"
  if docker manifest inspect "$IMAGE" 2>/dev/null | grep -q '"architecture": "arm64"'; then
    ok "$IMAGE has a native arm64 build"
  else
    warn "No native arm64 build found for $IMAGE."
    warn "Docker will emulate x86 through Rosetta. It works but is noticeably"
    warn "slower. To force it explicitly, add to the service in docker-compose.yml:"
    warn "    platform: linux/amd64"
  fi
fi

info "Creating local directories"
mkdir -p data/{conf,flowfile_repository,content_repository,provenance_repository,database_repository,state,logs} sandbox
ok "data/ and sandbox/ ready"

info "Starting NiFi (first run pulls ~1.5 GB, be patient)"
$COMPOSE up -d
ok "container started"

info "Waiting for NiFi to answer. This normally takes 60-120 seconds."
printf '    '
for i in $(seq 1 60); do
  # -k because the certificate is self-signed and generated on first boot.
  if curl -kfs https://localhost:8443/nifi-api/access/config >/dev/null 2>&1; then
    printf '\n'; ok "NiFi is up after ~$((i*5))s"
    cat <<TXT

===========================================================================
  NiFi is ready.

    URL        $UI
    Username   admin
    Password   ChangeThisLocally123

  Your browser will warn about the certificate. That is expected - NiFi
  generated its own on first start. Click through it.

  Next:
    ./logs.sh                    follow the application log
    ./smoke-test-flow.sh         build a tiny working flow via the REST API
    ./export-everything.sh       export all flows and config to a folder
    ./stop.sh                    stop, keep your work
    ./stop.sh --wipe             stop and delete everything
===========================================================================
TXT
    exit 0
  fi
  printf '.'
  sleep 5
done

printf '\n'
warn "NiFi did not answer within 5 minutes. Most likely causes:"
warn "  1. Not enough memory for Docker (see above)"
warn "  2. The password is shorter than 12 characters -> NiFi refuses to start"
warn "  3. Port 8443 already in use"
echo
info "Last 40 log lines:"
$COMPOSE logs --tail 40 nifi
exit 1
