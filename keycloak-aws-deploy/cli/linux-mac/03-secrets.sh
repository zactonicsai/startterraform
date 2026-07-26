#!/usr/bin/env bash
# Generates random passwords and stores all three secrets in Secrets Manager.
. "$(dirname "$0")/lib/common.sh"
load_config; load_state

mk_secret() {  # mk_secret VAR NAME DESCRIPTION JSON
  local var="$1" name="$2" desc="$3" json="$4"
  if already_done "$var"; then warn "$var exists - skipping"; return; fi
  local arn
  # A name-suffix avoids collisions with a secret still in its deletion window
  local uniq="${name}-$(date +%s)"
  arn=$(aws secretsmanager create-secret --name "$uniq" --description "$desc" \
    --secret-string "$json" \
    --tags "Key=Project,Value=${PROJECT}" \
    --query 'ARN' --output text)
  save "$var" "$arn"
}

step "Generating strong random passwords"
DB_PASSWORD=$(gen_password)
KC_ADMIN_PASSWORD=$(gen_password)
ok "Generated (they go straight into Secrets Manager, not into any file)"

step "Storing database credentials"
mk_secret DB_SECRET_ARN "${PROJECT}/db-credentials" \
  "Keycloak RDS master credentials" \
  "{\"username\":\"kcadmin\",\"password\":\"${DB_PASSWORD}\",\"engine\":\"postgres\",\"port\":5432,\"dbname\":\"keycloak\"}"

step "Storing Artifactory pull credentials"
mk_secret ART_SECRET_ARN "${PROJECT}/artifactory-credentials" \
  "JFrog Artifactory pull credentials" \
  "{\"username\":\"${ARTIFACTORY_USER}\",\"token\":\"${ARTIFACTORY_TOKEN}\"}"

step "Storing the TEMPORARY Keycloak bootstrap admin"
mk_secret KC_SECRET_ARN "${PROJECT}/keycloak-bootstrap-admin" \
  "TEMPORARY bootstrap admin - delete the user after first login" \
  "{\"username\":\"tmpadmin\",\"password\":\"${KC_ADMIN_PASSWORD}\"}"

cat <<TXT

  Retrieve credentials later with:
    aws secretsmanager get-secret-value --secret-id "$DB_SECRET_ARN" \\
      --query SecretString --output text | jq

  The bootstrap admin is single-use. After your first login:
    1. create a real named admin account with MFA
    2. delete the 'tmpadmin' user
    3. delete the bootstrap secret

TXT
printf '%sSecrets ready. Next: ./04-iam.sh%s\n\n' "$C_GRN$C_BOLD" "$C_RESET"
