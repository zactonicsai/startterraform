#!/usr/bin/env bash
# ===========================================================================
#  Install the AWS Load Balancer Controller.
#
#  WHY: a Kubernetes Ingress object is just a request. Something has to read
#  it and build a real load balancer. On EKS that something is this controller,
#  which turns an Ingress into an actual ALB with target groups.
#
#  Without it, you apply the Ingress, nothing happens, and `kubectl get ingress`
#  shows a blank ADDRESS forever with no error explaining why.
# ===========================================================================
set -euo pipefail

CLUSTER="${CLUSTER:-nifi-cluster}"
REGION="${REGION:-eu-west-1}"

info() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '    \033[0;32m[ok]\033[0m %s\n' "$*"; }
die()  { printf '    \033[0;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

for t in kubectl helm eksctl aws jq; do command -v "$t" >/dev/null || die "$t not installed"; done
ok "tools present"

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
info "Cluster $CLUSTER in $REGION (account $ACCOUNT)"
kubectl get nodes >/dev/null 2>&1 || die "kubectl cannot reach the cluster. Run:
    aws eks update-kubeconfig --name $CLUSTER --region $REGION"
ok "$(kubectl get nodes --no-headers | wc -l | tr -d ' ') node(s) reachable"

info "IAM policy for the controller"
POLICY_ARN="arn:aws:iam::$ACCOUNT:policy/AWSLoadBalancerControllerIAMPolicy"
if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  ok "policy already exists"
else
  curl -fsSL -o /tmp/alb-policy.json \
    https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
  aws iam create-policy --policy-name AWSLoadBalancerControllerIAMPolicy \
    --policy-document file:///tmp/alb-policy.json >/dev/null
  ok "policy created"
fi

info "Service account with IRSA"
# IRSA maps a Kubernetes service account to an IAM role, so the controller gets
# permissions without giving every pod on the node the same access.
eksctl create iamserviceaccount \
  --cluster "$CLUSTER" --region "$REGION" \
  --namespace kube-system --name aws-load-balancer-controller \
  --attach-policy-arn "$POLICY_ARN" \
  --override-existing-serviceaccounts --approve
ok "service account bound to the IAM role"

info "Installing the controller"
helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName="$CLUSTER" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region="$REGION" \
  --wait
ok "controller running"

info "Verifying"
kubectl -n kube-system get deployment aws-load-balancer-controller
kubectl get storageclass
cat <<'TXT'

    Next:
      kubectl apply -f manifests/00-namespace.yaml
      # edit manifests/01-secrets.yaml FIRST - it has placeholder values
      kubectl apply -f manifests/
      kubectl -n nifi get pods -w

    If PVCs stay Pending, the EBS CSI driver addon is missing:
      eksctl get addon --cluster nifi-cluster | grep ebs
TXT
