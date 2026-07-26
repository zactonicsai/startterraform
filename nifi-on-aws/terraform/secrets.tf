resource "random_password" "sensitive_props" {
  count   = var.nifi_sensitive_props_key == "" ? 1 : 0
  length  = 40
  special = false
}

resource "random_password" "nifi_admin" {
  # NiFi refuses single-user passwords under 12 characters, with a message
  # that is easy to miss in the boot log.
  length  = 20
  special = false
}

locals {
  sensitive_props_key = var.nifi_sensitive_props_key != "" ? var.nifi_sensitive_props_key : random_password.sensitive_props[0].result
}

resource "aws_secretsmanager_secret" "artifactory" {
  name        = "${var.project}/artifactory"
  description = "Artifactory pull credentials"
  # 0 = delete immediately. Default is a 30-day window during which the NAME
  # stays reserved, so a re-apply after destroy fails with "already exists".
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "artifactory" {
  secret_id = aws_secretsmanager_secret.artifactory.id
  secret_string = jsonencode({
    username = var.artifactory_user
    password = var.artifactory_password
  })
}

resource "aws_secretsmanager_secret" "sensitive_props_key" {
  name                    = "${var.project}/sensitive-props-key"
  description             = "NiFi nifi.sensitive.props.key - LOSING THIS MAKES FLOW SECRETS UNREADABLE"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "sensitive_props_key" {
  secret_id     = aws_secretsmanager_secret.sensitive_props_key.id
  secret_string = local.sensitive_props_key
}

resource "aws_secretsmanager_secret" "nifi_admin" {
  name                    = "${var.project}/nifi-admin"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "nifi_admin" {
  secret_id = aws_secretsmanager_secret.nifi_admin.id
  secret_string = jsonencode({
    username = "admin"
    password = random_password.nifi_admin.result
  })
}
