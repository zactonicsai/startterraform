#!/usr/bin/env bash
# Creates the least-privilege EC2 role + instance profile.
. "$(dirname "$0")/lib/common.sh"
load_config
require_state DB_SECRET_ARN ART_SECRET_ARN KC_SECRET_ARN

ROLE_NAME="${PROJECT}-ec2-role"
save ROLE_NAME "$ROLE_NAME"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

step "Creating the IAM role"
cat > "$TMP/trust.json" << 'JSON'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "ec2.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
JSON
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  warn "Role $ROLE_NAME already exists - skipping creation"
else
  aws iam create-role --role-name "$ROLE_NAME" \
    --assume-role-policy-document "file://$TMP/trust.json" \
    --tags "Key=Project,Value=${PROJECT}" >/dev/null
  ok "Role created"
fi

step "Attaching AWS managed policies"
for P in AmazonSSMManagedInstanceCore CloudWatchAgentServerPolicy; do
  aws iam attach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/$P" && ok "$P"
done

step "Attaching a least-privilege inline policy for exactly 3 secrets"
cat > "$TMP/secrets.json" << JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "ReadOnlyTheseThreeSecrets",
    "Effect": "Allow",
    "Action": ["secretsmanager:GetSecretValue"],
    "Resource": [
      "${DB_SECRET_ARN}",
      "${ART_SECRET_ARN}",
      "${KC_SECRET_ARN}"
    ]
  }]
}
JSON
aws iam put-role-policy --role-name "$ROLE_NAME" \
  --policy-name "${PROJECT}-read-secrets" \
  --policy-document "file://$TMP/secrets.json"
ok "Named ARNs only - never Resource: *"

step "Creating the instance profile"
if aws iam get-instance-profile --instance-profile-name "$ROLE_NAME" >/dev/null 2>&1; then
  warn "Instance profile already exists"
else
  aws iam create-instance-profile --instance-profile-name "$ROLE_NAME" \
    --tags "Key=Project,Value=${PROJECT}" >/dev/null
  aws iam add-role-to-instance-profile \
    --instance-profile-name "$ROLE_NAME" --role-name "$ROLE_NAME"
  ok "Profile created and role attached"
fi

step "Waiting 15s for IAM to propagate globally"
sleep 15
printf '\n%sIAM ready. Next: ./05-rds.sh%s\n\n' "$C_GRN$C_BOLD" "$C_RESET"
