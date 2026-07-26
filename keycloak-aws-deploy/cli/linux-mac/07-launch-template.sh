#!/usr/bin/env bash
# Generates user-data from the template and creates the launch template.
. "$(dirname "$0")/lib/common.sh"
load_config
require_state SG_APP ROLE_NAME DB_ENDPOINT DB_SECRET_ARN ART_SECRET_ARN KC_SECRET_ARN

LOG_GROUP="/${PROJECT}/keycloak"
save LOG_GROUP "$LOG_GROUP"

step "Creating the CloudWatch log group"
aws logs create-log-group --log-group-name "$LOG_GROUP" \
  --tags "Project=${PROJECT}" >/dev/null 2>&1 \
  && ok "Log group created" || warn "Log group already exists"
aws logs put-retention-policy --log-group-name "$LOG_GROUP" --retention-in-days 14
ok "Retention set to 14 days (logs default to never expiring - that costs money)"

step "Generating user-data from templates/user-data.sh.tmpl"
GEN="$STATE_DIR/user-data-generated.sh"
sed -e "s|@@AWS_REGION@@|${AWS_REGION}|g" \
    -e "s|@@DB_SECRET_ARN@@|${DB_SECRET_ARN}|g" \
    -e "s|@@ART_SECRET_ARN@@|${ART_SECRET_ARN}|g" \
    -e "s|@@KC_SECRET_ARN@@|${KC_SECRET_ARN}|g" \
    -e "s|@@ARTIFACTORY_HOST@@|${ARTIFACTORY_HOST}|g" \
    -e "s|@@KC_IMAGE@@|${KC_IMAGE}|g" \
    -e "s|@@DB_ENDPOINT@@|${DB_ENDPOINT}|g" \
    -e "s|@@DOMAIN_NAME@@|${DOMAIN_NAME}|g" \
    -e "s|@@LOG_GROUP@@|${LOG_GROUP}|g" \
    "$TEMPLATE_DIR/user-data.sh.tmpl" > "$GEN"
grep -q '@@' "$GEN" && die "Some tokens were not replaced in $GEN"
ok "Written to $GEN"
bash -n "$GEN" || die "Generated user-data has a syntax error"
ok "Syntax check passed"

step "Finding the latest Amazon Linux 2023 AMI"
AMI_ID=$(aws ssm get-parameter \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameter.Value' --output text)
save AMI_ID "$AMI_ID"

step "Base64-encoding user-data"
if base64 --help 2>&1 | grep -q -- '-w'; then
  UD=$(base64 -w0 "$GEN")          # GNU / Linux
else
  UD=$(base64 -i "$GEN" | tr -d '\n')  # BSD / macOS
fi

step "Creating the launch template"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/lt.json" << JSON
{
  "ImageId": "${AMI_ID}",
  "InstanceType": "${INSTANCE_TYPE}",
  "IamInstanceProfile": { "Name": "${ROLE_NAME}" },
  "SecurityGroupIds": ["${SG_APP}"],
  "UserData": "${UD}",
  "MetadataOptions": {
    "HttpEndpoint": "enabled",
    "HttpTokens": "required",
    "HttpPutResponseHopLimit": 2,
    "InstanceMetadataTags": "enabled"
  },
  "Monitoring": { "Enabled": true },
  "BlockDeviceMappings": [{
    "DeviceName": "/dev/xvda",
    "Ebs": {
      "VolumeSize": 30,
      "VolumeType": "gp3",
      "Encrypted": true,
      "DeleteOnTermination": true
    }
  }],
  "TagSpecifications": [
    { "ResourceType": "instance",
      "Tags": [{"Key":"Name","Value":"${PROJECT}-node"},{"Key":"Project","Value":"${PROJECT}"}] },
    { "ResourceType": "volume",
      "Tags": [{"Key":"Name","Value":"${PROJECT}-volume"},{"Key":"Project","Value":"${PROJECT}"}] }
  ]
}
JSON

if already_done LT_ID; then
  step "Launch template exists - creating a NEW VERSION instead"
  VER=$(aws ec2 create-launch-template-version \
    --launch-template-id "$LT_ID" \
    --version-description "updated $(date -u +%Y%m%dT%H%M%SZ)" \
    --launch-template-data "file://$TMP/lt.json" \
    --query 'LaunchTemplateVersion.VersionNumber' --output text)
  ok "Created version $VER"
  info "Roll it out with: aws autoscaling start-instance-refresh --auto-scaling-group-name ${PROJECT}-asg"
else
  LT_ID=$(aws ec2 create-launch-template \
    --launch-template-name "${PROJECT}-lt" \
    --version-description "v1 initial" \
    --launch-template-data "file://$TMP/lt.json" \
    --tag-specifications "ResourceType=launch-template,Tags=[{Key=Project,Value=${PROJECT}}]" \
    --query 'LaunchTemplate.LaunchTemplateId' --output text)
  save LT_ID "$LT_ID"
fi

info "IMDSv2 is required on this template - protects IAM creds from SSRF."
printf '\n%sLaunch template ready. Next: ./08-asg.sh%s\n\n' "$C_GRN$C_BOLD" "$C_RESET"
