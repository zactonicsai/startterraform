#!/usr/bin/env bash
# Creates the Multi-AZ PostgreSQL database. This is the slowest step (10-20 min).
. "$(dirname "$0")/lib/common.sh"
load_config
require_state DB_A DB_B SG_RDS DB_SECRET_ARN

DB_ID="${PROJECT}-db"
save DB_ID "$DB_ID"
SUBNET_GROUP="${PROJECT}-db-subnets"
save DB_SUBNET_GROUP "$SUBNET_GROUP"

step "Creating the DB subnet group (needs >= 2 AZs for Multi-AZ)"
aws rds create-db-subnet-group \
  --db-subnet-group-name "$SUBNET_GROUP" \
  --db-subnet-group-description "Private data subnets for Keycloak" \
  --subnet-ids "$DB_A" "$DB_B" \
  --tags "Key=Project,Value=${PROJECT}" >/dev/null 2>&1 \
  && ok "Subnet group created" || warn "Subnet group already exists"

step "Selecting a current PostgreSQL major version"
PG_MAJOR=$(aws rds describe-db-engine-versions --engine postgres \
  --query 'DBEngineVersions[?SupportedEngineModes==null || contains(SupportedEngineModes, `provisioned`)].EngineVersion' \
  --output text | tr '\t' '\n' | cut -d. -f1 | sort -n | tail -1)
[ -n "$PG_MAJOR" ] || PG_MAJOR=16
info "Using PostgreSQL major version $PG_MAJOR (AWS picks the latest minor)"
save PG_MAJOR "$PG_MAJOR"

if aws rds describe-db-instances --db-instance-identifier "$DB_ID" >/dev/null 2>&1; then
  warn "Database $DB_ID already exists - skipping creation"
else
  step "Reading the master password back out of Secrets Manager"
  DB_PASSWORD=$(aws secretsmanager get-secret-value --secret-id "$DB_SECRET_ARN" \
    --query SecretString --output text | jq -r .password)
  [ -n "$DB_PASSWORD" ] || die "Could not read the database password."

  MULTIAZ_FLAG="--multi-az"
  [ "${DB_MULTI_AZ:-true}" = "true" ] || MULTIAZ_FLAG="--no-multi-az"

  step "Creating RDS instance $DB_ID (this takes 10-20 minutes)"
  info "Multi-AZ: ${DB_MULTI_AZ:-true}  Class: ${DB_INSTANCE_CLASS}  Storage: ${DB_ALLOCATED_STORAGE}GB gp3"
  aws rds create-db-instance \
    --db-instance-identifier "$DB_ID" \
    --db-instance-class "${DB_INSTANCE_CLASS}" \
    --engine postgres \
    --engine-version "$PG_MAJOR" \
    --master-username kcadmin \
    --master-user-password "$DB_PASSWORD" \
    --db-name keycloak \
    --allocated-storage "${DB_ALLOCATED_STORAGE}" \
    --max-allocated-storage $(( DB_ALLOCATED_STORAGE * 5 )) \
    --storage-type gp3 \
    --storage-encrypted \
    $MULTIAZ_FLAG \
    --db-subnet-group-name "$SUBNET_GROUP" \
    --vpc-security-group-ids "$SG_RDS" \
    --no-publicly-accessible \
    --backup-retention-period "${DB_BACKUP_RETENTION:-7}" \
    --preferred-backup-window "03:00-04:00" \
    --preferred-maintenance-window "sun:04:30-sun:05:30" \
    --auto-minor-version-upgrade \
    --deletion-protection \
    --enable-performance-insights \
    --copy-tags-to-snapshot \
    --enable-cloudwatch-logs-exports postgresql upgrade \
    --tags "Key=Project,Value=${PROJECT}" >/dev/null
  ok "Creation started"
fi

step "Waiting for the database to become available"
info "Go get a coffee. Multi-AZ provisioning is genuinely slow."
aws rds wait db-instance-available --db-instance-identifier "$DB_ID"

DB_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier "$DB_ID" \
  --query 'DBInstances[0].Endpoint.Address' --output text)
save DB_ENDPOINT "$DB_ENDPOINT"

info "Deletion protection is ON. destroy-all.sh will ask before removing it."
printf '\n%sDatabase ready. Next: ./06-alb.sh%s\n\n' "$C_GRN$C_BOLD" "$C_RESET"
