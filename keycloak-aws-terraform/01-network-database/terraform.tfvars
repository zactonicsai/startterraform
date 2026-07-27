# ===========================================================================
# terraform.tfvars  -  STACK 1 (network + database + secret)
#
# This is the ONLY file most people need to edit.
# Terraform loads it automatically. Change a value, run apply, done.
# ===========================================================================

# --- Identity -------------------------------------------------------------
# project_name + environment are glued together to name every resource,
# for example "keycloak-dev-vpc". Change environment to "test" and you get a
# completely separate copy of the whole system in the same account.
aws_region   = "us-east-1"
project_name = "keycloak"
environment  = "dev"

extra_tags = {
  Owner      = "platform-team"
  CostCenter = "sandbox"
}

# --- Network --------------------------------------------------------------
vpc_cidr                = "10.20.0.0/16"
availability_zone_count = 2

# NAT Gateway lets the private Keycloak servers download the Docker image.
# It is the single biggest fixed cost here (~USD 32/month each).
# single_nat_gateway = true means one shared gateway instead of one per AZ.
enable_nat_gateway = true
single_nat_gateway = true

enable_vpc_flow_logs = false

# --- Database -------------------------------------------------------------
db_engine_version        = "16"
db_instance_class        = "db.t4g.micro" # ~USD 12/month, fine for testing
db_allocated_storage     = 20
db_max_allocated_storage = 100
db_name                  = "keycloak"
db_username              = "kcadmin"

# Cheap dev settings. See docs/02-best-practices.md for the production values.
db_multi_az              = false
db_backup_retention_days = 7
db_deletion_protection   = false
db_skip_final_snapshot   = true

# --- Secrets --------------------------------------------------------------
# 0 = secret disappears immediately on destroy, so you can rebuild right away.
# Use 7-30 in production so a mistake can be undone.
secret_recovery_window_days = 0
