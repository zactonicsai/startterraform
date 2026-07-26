#!/usr/bin/env bash
# Builds the optimized Keycloak image and pushes it to Artifactory.
# Usage: ./build-and-push.sh [keycloak-version]
set -euo pipefail

# Read shared config if present
CFG="$(cd "$(dirname "$0")/.." && pwd)/config.env"
[ -f "$CFG" ] && { set -a; . "$CFG"; set +a; }

KC_VERSION="${1:-26.4.0}"
: "${ARTIFACTORY_HOST:?set ARTIFACTORY_HOST in config.env or the environment}"
: "${ARTIFACTORY_USER:?set ARTIFACTORY_USER}"
: "${ARTIFACTORY_TOKEN:?set ARTIFACTORY_TOKEN}"
REPO="${ARTIFACTORY_REPO:-docker-local}"

TAG="${ARTIFACTORY_HOST}/${REPO}/keycloak:${KC_VERSION}-optimized"

echo "==> Building $TAG"
docker build \
  --build-arg "KEYCLOAK_VERSION=${KC_VERSION}" \
  -t "$TAG" \
  "$(dirname "$0")"

echo "==> Logging in to $ARTIFACTORY_HOST"
# --password-stdin keeps the token out of the process list
echo "$ARTIFACTORY_TOKEN" | docker login "$ARTIFACTORY_HOST" \
  --username "$ARTIFACTORY_USER" --password-stdin

echo "==> Pushing"
docker push "$TAG"

echo "==> Cleaning up local credentials"
docker logout "$ARTIFACTORY_HOST"

cat <<TXT

Done. Now set this in your config:

  config.env         KC_IMAGE=$TAG
  terraform.tfvars   keycloak_image = "$TAG"

Then roll it out:
  CLI       ./cli/linux-mac/07-launch-template.sh   (creates a new version)
            aws autoscaling start-instance-refresh --auto-scaling-group-name <asg>
  Terraform make plan && make apply                (instance_refresh handles it)

TXT
