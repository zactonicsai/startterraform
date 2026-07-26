#!/usr/bin/env bash
# ===========================================================================
# The instance role. Instances get permissions by ASSUMING a role, so no
# access key is ever written to disk. If someone takes a snapshot of the
# volume, there is no credential in it.
# ===========================================================================
source "$(dirname "$0")/lib/common.sh"

ROLE="$PROJECT-node-role"
PROFILE="$PROJECT-node-profile"

info "IAM role"
if aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  skip "role $ROLE exists"
else
  aws iam create-role --role-name "$ROLE" \
    --description "NiFi EC2 nodes for $PROJECT" \
    --assume-role-policy-document '{
      "Version":"2012-10-17",
      "Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]
    }' >/dev/null
  ok "created $ROLE"
fi
remember IAM_ROLE "$ROLE"

info "AWS-managed policies"
# Session Manager: shell access with no SSH key and no open port 22.
aws iam attach-role-policy --role-name "$ROLE" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
ok "AmazonSSMManagedInstanceCore (shell access without SSH)"
# CloudWatch agent: ship nifi-app.log off the box, so a terminated instance
# does not take the evidence with it.
aws iam attach-role-policy --role-name "$ROLE" \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy
ok "CloudWatchAgentServerPolicy (log shipping)"

info "Least-privilege inline policy"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
# Note the resource ARNs: this role can read exactly THREE named secrets,
# not every secret in the account. If the instance is compromised, the blast
# radius is those three values.
cat > "$STATE_DIR/inline-policy.json" << JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadOnlyOurThreeSecrets",
      "Effect": "Allow",
      "Action": ["secretsmanager:GetSecretValue"],
      "Resource": [
        "arn:aws:secretsmanager:$AWS_REGION:$ACCOUNT:secret:$PROJECT/artifactory-*",
        "arn:aws:secretsmanager:$AWS_REGION:$ACCOUNT:secret:$PROJECT/sensitive-props-key-*",
        "arn:aws:secretsmanager:$AWS_REGION:$ACCOUNT:secret:$PROJECT/nifi-admin-*"
      ]
    },
    {
      "Sid": "DescribeOwnVolumesForMount",
      "Effect": "Allow",
      "Action": ["ec2:DescribeVolumes", "ec2:DescribeTags"],
      "Resource": "*"
    }
  ]
}
JSON
aws iam put-role-policy --role-name "$ROLE" \
  --policy-name "$PROJECT-node-inline" \
  --policy-document "file://$STATE_DIR/inline-policy.json"
ok "can read only the 3 secrets this project owns"

info "Instance profile"
if aws iam get-instance-profile --instance-profile-name "$PROFILE" >/dev/null 2>&1; then
  skip "profile exists"
else
  aws iam create-instance-profile --instance-profile-name "$PROFILE" >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name "$PROFILE" --role-name "$ROLE"
  ok "created $PROFILE and added the role"
fi
remember IAM_PROFILE "$PROFILE"

info "Waiting for IAM to propagate"
# IAM is eventually consistent globally. Launching an instance immediately
# after creating a profile fails with a confusing "Invalid IAM Instance
# Profile name" that fixes itself if you just wait.
sleep 12
ok "done"
