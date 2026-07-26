#!/usr/bin/env bash
# ===========================================================================
# Three secrets, in Secrets Manager. None of them is ever written into a
# launch template, an AMI, or this repository.
#
#   1. Artifactory password  - to pull the NiFi image
#   2. Sensitive props key   - encrypts passwords INSIDE your flows
#   3. NiFi admin password   - the single-user login
#
# Number 2 deserves special attention and gets a warning below.
# ===========================================================================
source "$(dirname "$0")/lib/common.sh"

put_secret() {  # put_secret name description value
  local name="$1" desc="$2" value="$3"
  if aws secretsmanager describe-secret --secret-id "$name" >/dev/null 2>&1; then
    local st
    st=$(aws secretsmanager describe-secret --secret-id "$name" --query 'DeletedDate' --output text)
    if [ "$st" != "None" ]; then
      warn "$name is SCHEDULED FOR DELETION. Restoring it."
      # Deleted secrets keep their name reserved for the recovery window,
      # so a re-deploy after a teardown hits "already exists". This is why.
      aws secretsmanager restore-secret --secret-id "$name" >/dev/null
    fi
    skip "$name exists (not overwriting)"
  else
    aws secretsmanager create-secret --name "$name" --description "$desc" \
      --secret-string "$value" \
      --tags "Key=Project,Value=$PROJECT" >/dev/null
    ok "created $name"
  fi
}

info "1/3  Artifactory pull credentials"
if [ -n "${ARTIFACTORY_PASSWORD:-}" ]; then
  PW="$ARTIFACTORY_PASSWORD"
else
  printf '    Artifactory password / API token for %s (not echoed): ' "$ARTIFACTORY_USER"
  read -rs PW; echo
fi
[ -n "$PW" ] || die "an Artifactory credential is required to pull the image"
put_secret "$PROJECT/artifactory" "Artifactory pull creds for $PROJECT" \
  "{\"username\":\"$ARTIFACTORY_USER\",\"password\":\"$PW\"}"
unset PW

info "2/3  NiFi sensitive properties key"
cat << 'TXT'
    ------------------------------------------------------------------
     WHAT THIS IS, AND WHY IT MATTERS MORE THAN IT LOOKS

     NiFi encrypts every sensitive property inside your flow - database
     passwords, API keys, keystore passwords - with this one key.

     Consequences:
       * Every node in a cluster MUST use the identical key, or nodes
         refuse to join because they cannot read each other's flow.
       * It must SURVIVE an upgrade. Restore a flow with a different key
         and every encrypted value becomes unreadable.
       * Exported flow definitions carry encrypted values. Without this
         key, an export is only half a backup.

     Store it somewhere you will still have it in two years.
    ------------------------------------------------------------------
TXT
if aws secretsmanager describe-secret --secret-id "$PROJECT/sensitive-props-key" >/dev/null 2>&1; then
  skip "key already exists - NOT regenerating (that would break existing flows)"
else
  KEY=$(openssl rand -base64 32 | tr -d '\n')
  put_secret "$PROJECT/sensitive-props-key" "NiFi nifi.sensitive.props.key - DO NOT LOSE" "$KEY"
  echo
  warn "Copy this into your password manager NOW:"
  printf '\n      %s\n\n' "$KEY"
  unset KEY
fi

info "3/3  NiFi admin password"
if aws secretsmanager describe-secret --secret-id "$PROJECT/nifi-admin" >/dev/null 2>&1; then
  skip "exists"
else
  # NiFi rejects single-user passwords shorter than 12 characters at startup,
  # with a message that is easy to miss in the boot log.
  ADMIN_PW=$(openssl rand -base64 24 | tr -d '\n/+=' | cut -c1-20)
  put_secret "$PROJECT/nifi-admin" "NiFi single-user admin login" \
    "{\"username\":\"admin\",\"password\":\"$ADMIN_PW\"}"
  warn "Admin login -> admin / $ADMIN_PW"
  unset ADMIN_PW
fi

info "Verifying the role can actually read them"
for s in artifactory sensitive-props-key nifi-admin; do
  if aws secretsmanager describe-secret --secret-id "$PROJECT/$s" >/dev/null 2>&1; then
    ok "$PROJECT/$s present"
  else
    die "$PROJECT/$s missing"
  fi
done
remember SECRETS_READY "yes"
ok "Secrets complete"
