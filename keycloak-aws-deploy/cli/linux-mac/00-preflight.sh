#!/usr/bin/env bash
# Verifies your tools, credentials and config BEFORE anything is created.
. "$(dirname "$0")/lib/common.sh"
load_config

step "Checking required commands"
for c in aws jq curl base64; do need_cmd "$c"; ok "$c found"; done

step "Checking AWS CLI version"
V=$(aws --version 2>&1)
info "$V"
case "$V" in aws-cli/2.*) ok "AWS CLI v2" ;; *) warn "AWS CLI v2 recommended" ;; esac

step "Checking AWS credentials"
ID=$(aws sts get-caller-identity --output json) || die "Cannot authenticate to AWS."
info "Account : $(echo "$ID" | jq -r .Account)"
info "Identity: $(echo "$ID" | jq -r .Arn)"
info "Region  : $AWS_REGION"
ok "Credentials valid"

step "Confirming this is the intended account"
confirm "Deploy '$PROJECT' into account $(echo "$ID" | jq -r .Account) / $AWS_REGION ? Type yes:"

step "Validating config values"
[ "$ACM_CERT_ARN" = "" ] || case "$ACM_CERT_ARN" in
  *REPLACE-ME*) die "ACM_CERT_ARN still contains REPLACE-ME." ;;
esac
case "$KC_IMAGE" in
  *REPLACE-ME*|"") die "KC_IMAGE is not set." ;;
  *:latest)       die "KC_IMAGE uses ':latest'. Pin an explicit version tag." ;;
  *:*)            ok "Image tag is pinned: $KC_IMAGE" ;;
  *)              die "KC_IMAGE has no tag. Pin an explicit version." ;;
esac
case "$ARTIFACTORY_TOKEN" in *REPLACE-ME*|"") die "ARTIFACTORY_TOKEN is not set." ;; esac
ok "Config looks sane"

step "Verifying the ACM certificate exists in this region"
aws acm describe-certificate --certificate-arn "$ACM_CERT_ARN" \
  --query 'Certificate.[DomainName,Status]' --output text \
  || die "Certificate not found in $AWS_REGION. ACM certs for an ALB must be in the SAME region."

step "Checking service permissions"
aws ec2 describe-vpcs --max-items 1 >/dev/null    || die "No EC2 read permission."
aws rds describe-db-instances --max-items 1 >/dev/null || die "No RDS read permission."
aws elbv2 describe-load-balancers --max-items 1 >/dev/null || die "No ELB read permission."
aws secretsmanager list-secrets --max-results 1 >/dev/null || die "No Secrets Manager permission."
ok "Permissions look sufficient"

step "Checking availability zones"
AZS=$(aws ec2 describe-availability-zones --filters Name=state,Values=available \
  --query 'AvailabilityZones[].ZoneName' --output text)
info "Available: $AZS"
N=$(echo "$AZS" | wc -w)
[ "$N" -ge 2 ] || die "Need at least 2 availability zones."
ok "$N zones available"

printf '\n%sPreflight passed. Next: ./01-network.sh%s\n\n' "$C_GRN$C_BOLD" "$C_RESET"
