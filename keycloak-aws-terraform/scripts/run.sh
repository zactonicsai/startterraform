#!/usr/bin/env bash
# ===========================================================================
# run.sh - one command to drive all three Terraform stacks.
#
#   ./scripts/run.sh <command> [stack] [extra terraform flags...]
#
# STACKS
#   db | database | network | 1   -> 01-network-database
#   keycloak | compute | app | 2  -> 02-keycloak-compute
#   alb | lb | public | 3         -> 03-public-access
#   all                           -> every stack, in the safe order
#
# COMMANDS
#   init         download providers
#   validate     check the code is correct
#   fmt          tidy the formatting
#   plan         show what WOULD change (changes nothing)
#   apply        build or update
#   reconfigure  apply again after you edited terraform.tfvars
#   redeploy     roll the Keycloak servers so they pick up a new image/config
#   destroy      delete (asks for confirmation)
#   output       print the outputs of a stack
#   status       quick health summary of the whole system
#   clean        remove local .terraform folders and plan files
#
# EXAMPLES
#   ./scripts/run.sh apply all            # build everything
#   ./scripts/run.sh plan keycloak        # preview changes to stack 2 only
#   ./scripts/run.sh destroy alb          # take the site offline, keep data
#   ./scripts/run.sh reconfigure keycloak # new image tag from tfvars
#   ./scripts/run.sh redeploy             # rolling restart of Keycloak
#   AUTO_APPROVE=1 ./scripts/run.sh apply all
# ===========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

STACK_1="01-network-database"
STACK_2="02-keycloak-compute"
STACK_3="03-public-access"

# Use OpenTofu if Terraform is not installed. Override with TF_BIN=...
TF_BIN="${TF_BIN:-}"
if [ -z "$TF_BIN" ]; then
  if command -v terraform >/dev/null 2>&1; then
    TF_BIN="terraform"
  elif command -v tofu >/dev/null 2>&1; then
    TF_BIN="tofu"
  else
    echo "ERROR: neither 'terraform' nor 'tofu' is installed and on your PATH." >&2
    exit 1
  fi
fi

AUTO_APPROVE="${AUTO_APPROVE:-0}"

# ------------------------------- pretty output -----------------------------
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_BLD=$'\033[1m';  C_OFF=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BLD=""; C_OFF=""
fi

info()  { echo "${C_BLU}==>${C_OFF} $*"; }
ok()    { echo "${C_GRN}OK :${C_OFF} $*"; }
warn()  { echo "${C_YEL}!! :${C_OFF} $*"; }
err()   { echo "${C_RED}ERR:${C_OFF} $*" >&2; }
title() { echo; echo "${C_BLD}------------------------------------------------------------${C_OFF}"; echo "${C_BLD} $*${C_OFF}"; echo "${C_BLD}------------------------------------------------------------${C_OFF}"; }

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; }

# --------------------------- argument handling -----------------------------
resolve_stack() {
  case "${1:-}" in
    1|db|database|network|net)            echo "$STACK_1" ;;
    2|kc|keycloak|compute|app|asg)        echo "$STACK_2" ;;
    3|alb|lb|elb|public|internet|access)  echo "$STACK_3" ;;
    all|"")                               echo "all" ;;
    *) err "Unknown stack '${1}'. Use: db | keycloak | alb | all"; exit 2 ;;
  esac
}

confirm() {
  [ "$AUTO_APPROVE" = "1" ] && return 0
  local prompt="$1" answer
  echo
  warn "$prompt"
  printf "Type %syes%s to continue: " "$C_BLD" "$C_OFF"
  read -r answer
  [ "$answer" = "yes" ] || { info "Cancelled - nothing was changed."; exit 0; }
}

require_dir() {
  [ -d "$ROOT_DIR/$1" ] || { err "Stack folder '$1' not found under $ROOT_DIR"; exit 1; }
}

approve_flag() { [ "$AUTO_APPROVE" = "1" ] && echo "-auto-approve" || echo ""; }

# ------------------------------- primitives --------------------------------
tf() { # tf <stack-dir> <terraform args...>
  local dir="$1"; shift
  require_dir "$dir"
  ( cd "$ROOT_DIR" && "$TF_BIN" -chdir="$dir" "$@" )
}

do_init()     { title "INIT $1";     tf "$1" init -input=false -upgrade ${EXTRA[@]+"${EXTRA[@]}"}; }
do_validate() { title "VALIDATE $1"; tf "$1" init -input=false -backend=false >/dev/null; tf "$1" validate; }
do_plan()     { title "PLAN $1";     ensure_init "$1"; tf "$1" plan -input=false -out=tfplan.out ${EXTRA[@]+"${EXTRA[@]}"}; }
do_output()   { title "OUTPUT $1";   tf "$1" output || warn "No outputs yet - has this stack been applied?"; }

ensure_init() {
  [ -d "$ROOT_DIR/$1/.terraform" ] || { info "First run for $1 - initialising"; tf "$1" init -input=false >/dev/null; }
}

do_apply() {
  title "APPLY $1"
  ensure_init "$1"
  # shellcheck disable=SC2046
  tf "$1" apply -input=false $(approve_flag) ${EXTRA[@]+"${EXTRA[@]}"}
  ok "$1 applied"
}

do_destroy() {
  title "DESTROY $1"
  ensure_init "$1"
  # shellcheck disable=SC2046
  tf "$1" destroy -input=false $(approve_flag) ${EXTRA[@]+"${EXTRA[@]}"}
  ok "$1 destroyed"
}

# --------------------------- higher level actions --------------------------
cmd_apply() {
  local stack="$1"
  if [ "$stack" = "all" ]; then
    # Order matters: the database must exist before Keycloak can read its
    # secret, and Keycloak must exist before the load balancer can attach it.
    do_apply "$STACK_1"; do_apply "$STACK_2"; do_apply "$STACK_3"
    echo; ok "Everything is up. Your URL:"
    tf "$STACK_3" output -raw keycloak_admin_console_url 2>/dev/null && echo
  else
    do_apply "$stack"
  fi
}

cmd_destroy() {
  local stack="$1"
  if [ "$stack" = "all" ]; then
    confirm "This deletes EVERYTHING including the database and all Keycloak users."
    # Reverse order: unplug the front door first, remove the land last.
    do_destroy "$STACK_3"; do_destroy "$STACK_2"; do_destroy "$STACK_1"
  else
    case "$stack" in
      "$STACK_1") confirm "Stack 1 holds the DATABASE. Destroying it deletes every realm, user and client. Destroy stacks 3 and 2 first." ;;
      "$STACK_2") confirm "This removes the Keycloak servers. Your data survives in the database. The site will be down until you apply stack 2 again." ;;
      "$STACK_3") confirm "This removes the load balancer. Keycloak keeps running but nobody can reach it from the internet. The public URL will change when you rebuild." ;;
    esac
    do_destroy "$stack"
  fi
}

cmd_reconfigure() {
  local stack="$1"
  info "Reconfigure = apply again using the current terraform.tfvars values."
  if [ "$stack" = "all" ]; then
    do_apply "$STACK_1"; do_apply "$STACK_2"; do_apply "$STACK_3"
  else
    do_apply "$stack"
  fi
  if [ "$stack" = "$STACK_2" ] || [ "$stack" = "all" ]; then
    warn "Changing settings updates the launch template, but running servers keep the OLD settings"
    warn "until they are replaced. Run: ./scripts/run.sh redeploy"
  fi
}

cmd_redeploy() {
  title "REDEPLOY Keycloak servers"
  local region asg
  region="$(tf "$STACK_2" output -raw aws_region 2>/dev/null || true)"
  asg="$(tf "$STACK_2" output -raw autoscaling_group_name 2>/dev/null || true)"
  if [ -z "$asg" ]; then
    err "Could not read the Auto Scaling group name. Apply stack 2 first."
    exit 1
  fi
  info "Applying stack 2 so the launch template is current..."
  do_apply "$STACK_2"
  info "Starting a rolling instance refresh on $asg"
  aws autoscaling start-instance-refresh \
    --auto-scaling-group-name "$asg" \
    ${region:+--region "$region"} \
    --preferences '{"MinHealthyPercentage":50,"InstanceWarmup":300}' >/dev/null
  ok "Refresh started. Watch it with:"
  echo "    aws autoscaling describe-instance-refreshes --auto-scaling-group-name $asg ${region:+--region $region}"
}

cmd_status() {
  title "STATUS"
  local asg region tg
  region="$(tf "$STACK_2" output -raw aws_region 2>/dev/null || true)"
  asg="$(tf "$STACK_2" output -raw autoscaling_group_name 2>/dev/null || true)"
  tg="$(tf "$STACK_3" output -raw target_group_arn 2>/dev/null || true)"

  echo "Database endpoint : $(tf "$STACK_1" output -raw database_endpoint 2>/dev/null || echo 'not deployed')"
  echo "Auto Scaling group: ${asg:-not deployed}"
  echo "Public URL        : $(tf "$STACK_3" output -raw keycloak_url 2>/dev/null || echo 'not deployed')"

  if [ -n "$tg" ] && command -v aws >/dev/null 2>&1; then
    echo
    info "Load balancer view of the servers:"
    aws elbv2 describe-target-health --target-group-arn "$tg" ${region:+--region "$region"} \
      --query 'TargetHealthDescriptions[].{Instance:Target.Id,State:TargetHealth.State,Why:TargetHealth.Reason}' \
      --output table 2>/dev/null || warn "Could not query target health (check AWS credentials)."
  fi
}

cmd_clean() {
  confirm "Delete local .terraform folders and plan files? (Cloud resources are NOT touched.)"
  for d in "$STACK_1" "$STACK_2" "$STACK_3"; do
    rm -rf "${ROOT_DIR:?}/$d/.terraform" "${ROOT_DIR:?}/$d/tfplan.out"
    info "cleaned $d"
  done
  ok "Local cache removed. Run init again before the next plan."
}

cmd_fmt() { title "FORMAT"; ( cd "$ROOT_DIR" && "$TF_BIN" fmt -recursive ); ok "formatted"; }

for_each_stack() { # for_each_stack <function>
  local fn="$1" stack="$2"
  if [ "$stack" = "all" ]; then
    "$fn" "$STACK_1"; "$fn" "$STACK_2"; "$fn" "$STACK_3"
  else
    "$fn" "$stack"
  fi
}

# --------------------------------- main ------------------------------------
COMMAND="${1:-help}"
[ $# -gt 0 ] && shift || true
STACK_ARG="${1:-all}"
case "${STACK_ARG}" in -*) STACK_ARG="all" ;; *) [ $# -gt 0 ] && shift || true ;; esac
STACK="$(resolve_stack "$STACK_ARG")"
EXTRA=("$@")

case "$COMMAND" in
  init)        for_each_stack do_init "$STACK" ;;
  validate)    for_each_stack do_validate "$STACK" ;;
  plan)        for_each_stack do_plan "$STACK" ;;
  output)      for_each_stack do_output "$STACK" ;;
  apply)       cmd_apply "$STACK" ;;
  destroy)     cmd_destroy "$STACK" ;;
  reconfigure) cmd_reconfigure "$STACK" ;;
  redeploy)    cmd_redeploy ;;
  status)      cmd_status ;;
  clean)       cmd_clean ;;
  fmt)         cmd_fmt ;;
  help|-h|--help) usage ;;
  *) err "Unknown command '$COMMAND'"; echo; usage; exit 2 ;;
esac
