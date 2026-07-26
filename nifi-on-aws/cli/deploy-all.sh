#!/usr/bin/env bash
# Run every step in order. Safe to re-run: each script skips finished work.
source "$(dirname "$0")/lib/common.sh"

cat <<TXT
===========================================================================
  Deploying NiFi $NIFI_VERSION
    project    $PROJECT
    region     $AWS_REGION
    nodes      $NODE_COUNT $(is_cluster && echo "(cluster: ALB + ZooKeeper)" || echo "(single node, no ALB)")
    image      $NIFI_IMAGE
===========================================================================
TXT
read -r -p "  Continue? [y/N] " a; [ "$a" = y ] || exit 1

cd "$(dirname "$0")"
for s in 00-preflight 01-network 02-security-groups 03-iam 04-secrets \
         05-zookeeper 06-nifi-nodes 07-alb; do
  printf '\n\033[1;35m######## %s ########\033[0m\n' "$s"
  ./"$s".sh || die "$s failed. Fix it and re-run ./deploy-all.sh - completed steps are skipped."
done

if is_cluster; then
  printf '\n\033[1;35m######## refresh proxy host with the ALB name ########\033[0m\n'
  ./06-nifi-nodes.sh --refresh-proxy
  info "Waiting 150s for NiFi to restart and register"
  sleep 150
fi

printf '\n\033[1;35m######## 08-verify ########\033[0m\n'
./08-verify.sh
