#!/usr/bin/env bash
# ===========================================================================
# Check everything BEFORE creating anything. Two minutes here saves the
# specific misery of discovering a missing permission at step six, with
# half the infrastructure built and already billing.
# ===========================================================================
source "$(dirname "$0")/lib/common.sh"

FAIL=0
check() { if "$@" >/dev/null 2>&1; then ok "$DESC"; else warn "$DESC"; FAIL=1; fi; }

info "Tools"
for t in aws jq docker curl; do
  if command -v "$t" >/dev/null; then ok "$t present"
  else warn "$t MISSING"; [ "$t" = docker ] || FAIL=1; fi
done

V=$(aws --version 2>&1 | head -1)
case "$V" in
  aws-cli/2*) ok "$V" ;;
  *) warn "$V - v2 is expected; v1 has different output defaults"; FAIL=1 ;;
esac

info "Identity and region"
if ID=$(aws sts get-caller-identity --output json 2>/dev/null); then
  ok "account $(echo "$ID" | jq -r .Account)"
  ok "identity $(echo "$ID" | jq -r .Arn)"
else
  die "Cannot call sts:GetCallerIdentity. Credentials are not working at all."
fi
ok "region $AWS_REGION"

info "Permissions - a read call per service we will use"
DESC="ec2:DescribeVpcs";            check aws ec2 describe-vpcs --max-items 1
DESC="ec2:DescribeSubnets";         check aws ec2 describe-subnets --max-items 1
DESC="ec2:DescribeSecurityGroups";  check aws ec2 describe-security-groups --max-items 1
DESC="ec2:DescribeInstances";       check aws ec2 describe-instances --max-items 1
DESC="ec2:DescribeVolumes";         check aws ec2 describe-volumes --max-items 1
DESC="elasticloadbalancing:Describe"; check aws elbv2 describe-load-balancers --page-size 1
DESC="iam:ListRoles";               check aws iam list-roles --max-items 1
DESC="secretsmanager:ListSecrets";  check aws secretsmanager list-secrets --max-results 1
DESC="ssm:DescribeParameters";      check aws ssm describe-parameters --max-results 1
DESC="logs:DescribeLogGroups";      check aws logs describe-log-groups --limit 1

info "Availability Zones"
AZS=$(aws ec2 describe-availability-zones \
        --filters Name=state,Values=available \
        --query 'AvailabilityZones[].ZoneName' --output text)
COUNT=$(echo "$AZS" | wc -w | tr -d ' ')
ok "$COUNT available: $AZS"
if is_cluster && [ "$COUNT" -lt 2 ]; then
  warn "A cluster needs at least 2 AZs and this region reports $COUNT"; FAIL=1
fi

info "Configuration sanity"
if is_cluster; then
  ok "NODE_COUNT=$NODE_COUNT - cluster mode (ALB + ZooKeeper will be created)"
  if [ $((NODE_COUNT % 2)) -eq 0 ]; then
    warn "NODE_COUNT is even. Use an odd number so elections cannot tie."
  fi
  if [ -z "${ACM_CERT_ARN:-}" ]; then
    warn "ACM_CERT_ARN is empty. Cluster mode creates an HTTPS load balancer"
    warn "  and needs a certificate IN THIS REGION ($AWS_REGION)."
    FAIL=1
  else
    if aws acm describe-certificate --certificate-arn "$ACM_CERT_ARN" >/dev/null 2>&1; then
      ST=$(aws acm describe-certificate --certificate-arn "$ACM_CERT_ARN" \
            --query 'Certificate.Status' --output text)
      [ "$ST" = "ISSUED" ] && ok "certificate ISSUED" || { warn "certificate status: $ST"; FAIL=1; }
    else
      warn "Cannot read that certificate in $AWS_REGION. Wrong region is the usual cause."
      FAIL=1
    fi
  fi
else
  ok "NODE_COUNT=1 - simple single-node mode (no ALB, no ZooKeeper)"
fi

case "${MY_IP_CIDR:-}" in
  ""|203.0.113.10/32) warn "MY_IP_CIDR still the example value. Set it: curl -s https://checkip.amazonaws.com"; FAIL=1 ;;
  *) ok "access restricted to $MY_IP_CIDR" ;;
esac

case "$NIFI_VERSION" in
  1.*)  warn "NiFi $NIFI_VERSION is 1.x, which is END OF LIFE (final release 1.28.1)."; FAIL=1 ;;
  2.[0-7].*) warn "NiFi $NIFI_VERSION is affected by CVE-2026-25903. Use 2.8.0 or later."; FAIL=1 ;;
  2.*) ok "NiFi $NIFI_VERSION" ;;
  *) warn "Cannot judge version '$NIFI_VERSION'" ;;
esac

info "Billing guard"
warn "This script cannot check whether you set a budget alert."
warn "  Cluster mode costs roughly \$250-400/month. Set one now:"
warn "  AWS Console -> Billing -> Budgets -> Create budget"

echo
if [ "$FAIL" -eq 0 ]; then
  ok "PREFLIGHT PASSED - safe to run ./deploy-all.sh"
else
  die "PREFLIGHT FAILED - fix the items above first. Nothing has been created."
fi
