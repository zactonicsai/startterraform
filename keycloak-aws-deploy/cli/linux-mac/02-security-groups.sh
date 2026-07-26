#!/usr/bin/env bash
# Creates the three chained security groups: ALB -> App -> RDS.
. "$(dirname "$0")/lib/common.sh"
load_config; require_state VPC_ID

mk_sg() {  # mk_sg VAR NAME DESCRIPTION
  local var="$1" name="$2" desc="$3"
  if already_done "$var"; then warn "$var exists - skipping"; return; fi
  local id
  id=$(aws ec2 create-security-group --group-name "$name" --description "$desc" \
    --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${name}},{Key=Project,Value=${PROJECT}}]" \
    --query 'GroupId' --output text)
  save "$var" "$id"
}

step "Creating security groups"
mk_sg SG_ALB "${PROJECT}-alb-sg" "Public HTTPS entry point"
mk_sg SG_APP "${PROJECT}-app-sg" "Keycloak EC2 instances"
mk_sg SG_RDS "${PROJECT}-rds-sg" "PostgreSQL - app tier only"

# ignore duplicate-rule errors so the script is re-runnable
allow_cidr() {  # allow_cidr SG PORT CIDR DESC
  aws ec2 authorize-security-group-ingress --group-id "$1" \
    --ip-permissions "IpProtocol=tcp,FromPort=$2,ToPort=$2,IpRanges=[{CidrIp=$3,Description=\"$4\"}]" \
    >/dev/null 2>&1 && ok "$4" || warn "rule already present: $4"
}
allow_sg() {    # allow_sg SG PORT SRCSG DESC  (also accepts PORT as "7800-7801")
  local from="${2%%-*}" to="${2##*-}"
  aws ec2 authorize-security-group-ingress --group-id "$1" \
    --ip-permissions "IpProtocol=tcp,FromPort=$from,ToPort=$to,UserIdGroupPairs=[{GroupId=$3,Description=\"$4\"}]" \
    >/dev/null 2>&1 && ok "$4" || warn "rule already present: $4"
}

step "ALB rules: HTTPS + HTTP from the internet"
allow_cidr "$SG_ALB" 443 0.0.0.0/0 "HTTPS from internet"
allow_cidr "$SG_ALB" 80  0.0.0.0/0 "HTTP for redirect to HTTPS"

step "App rules: only from the ALB, plus cluster gossip between nodes"
allow_sg "$SG_APP" 8080      "$SG_ALB" "App traffic from ALB only"
allow_sg "$SG_APP" 9000      "$SG_ALB" "Health checks from ALB"
allow_sg "$SG_APP" 7800-7801 "$SG_APP" "Infinispan/JGroups cluster"

step "RDS rules: PostgreSQL only from the app tier"
allow_sg "$SG_RDS" 5432 "$SG_APP" "PostgreSQL from Keycloak nodes"

info "Note: no port 22 rule. Shell access is via SSM Session Manager."
printf '\n%sSecurity groups ready. Next: ./03-secrets.sh%s\n\n' "$C_GRN$C_BOLD" "$C_RESET"
