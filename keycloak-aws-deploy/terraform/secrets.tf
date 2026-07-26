resource "random_password" "db" {
  length = 32
  # RDS rejects /, @, ", and space in a master password
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "random_password" "kc_bootstrap_admin" {
  length  = 32
  special = false
}

# ---------------------------------------------------------------------------
# name_prefix, not name, on every secret.
#
# Secrets Manager does not free a deleted name immediately - it holds it for
# the recovery window (7-30 days). With a fixed name, destroying and
# re-applying inside that window fails with:
#   "You can't create this secret because a secret with this name is
#    already scheduled for deletion."
# The random suffix sidesteps that entirely.
# ---------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "db" {
  name_prefix             = "${local.name}/db-credentials-"
  description             = "Keycloak RDS master credentials"
  recovery_window_in_days = var.environment == "prod" ? 30 : 7
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = "kcadmin"
    password = random_password.db.result
    engine   = "postgres"
    port     = 5432
    dbname   = "keycloak"
  })
}

resource "aws_secretsmanager_secret" "artifactory" {
  name_prefix             = "${local.name}/artifactory-"
  description             = "Artifactory pull credentials"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "artifactory" {
  secret_id = aws_secretsmanager_secret.artifactory.id
  secret_string = jsonencode({
    username = var.artifactory_username
    token    = var.artifactory_token
  })
}

resource "aws_secretsmanager_secret" "kc_admin" {
  name_prefix             = "${local.name}/keycloak-bootstrap-admin-"
  description             = "TEMPORARY bootstrap admin. Delete the user after first login."
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "kc_admin" {
  secret_id = aws_secretsmanager_secret.kc_admin.id
  secret_string = jsonencode({
    username = "tmpadmin"
    password = random_password.kc_bootstrap_admin.result
  })
}
