# ---------------------------------------------------------------------------
# database.tf  -  the PostgreSQL server Keycloak stores everything in,
#                 plus the secret that holds the connection details.
# ---------------------------------------------------------------------------

# A DB subnet group tells RDS "you may live in these private subnets".
resource "aws_db_subnet_group" "main" {
  name       = "${local.name_prefix}-db-subnets"
  subnet_ids = aws_subnet.private[*].id

  tags = { Name = "${local.name_prefix}-db-subnets" }
}

# ---------------------------- Security group -------------------------------
# A security group is a firewall around a resource.
# NOTE: it starts with NO inbound rules on purpose.
# Stack 2 (Keycloak) adds the single rule that lets Keycloak in on 5432.
# That keeps the rule next to the thing that needs it and avoids a loop
# where stack 1 needs stack 2 and stack 2 needs stack 1.
resource "aws_security_group" "database" {
  name        = "${local.name_prefix}-db-sg"
  description = "Postgres access for Keycloak only"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name_prefix}-db-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

# Databases do not need to start conversations with the internet.
# We still allow outbound so features like backups behave normally.
resource "aws_vpc_security_group_egress_rule" "database_all" {
  security_group_id = aws_security_group.database.id
  description       = "Allow all outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# ------------------------------- Password ----------------------------------
# Terraform makes a strong random password. Nobody types it, nobody sees it,
# and it never appears in git - only in AWS Secrets Manager.
resource "random_password" "db" {
  length  = var.db_password_length
  special = true
  # RDS forbids these characters in a master password.
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# ------------------------------ The database -------------------------------
resource "aws_db_instance" "main" {
  identifier = "${local.name_prefix}-postgres"

  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db.result
  port     = var.db_port

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage > 0 ? var.db_max_allocated_storage : null
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = var.kms_key_arn != "" ? var.kms_key_arn : null

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.database.id]
  publicly_accessible    = false # never expose a database to the internet
  multi_az               = var.db_multi_az

  backup_retention_period = var.db_backup_retention_days
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:04:30-sun:05:30"
  copy_tags_to_snapshot   = true

  auto_minor_version_upgrade = true
  apply_immediately          = var.db_apply_immediately
  deletion_protection        = var.db_deletion_protection
  skip_final_snapshot        = var.db_skip_final_snapshot
  final_snapshot_identifier  = var.db_skip_final_snapshot ? null : "${local.name_prefix}-final-${formatdate("YYYYMMDDhhmmss", timestamp())}"

  performance_insights_enabled = var.db_performance_insights_enabled

  tags = { Name = "${local.name_prefix}-postgres" }

  lifecycle {
    # The snapshot name uses the current time, which changes on every plan.
    # Ignoring it stops Terraform from wanting to rebuild the database.
    ignore_changes = [final_snapshot_identifier]
  }
}

# ----------------------------- The secret ----------------------------------
# One secret holds everything Keycloak needs to log in to PostgreSQL.
resource "aws_secretsmanager_secret" "db" {
  name                    = "${local.name_prefix}/database"
  description             = "PostgreSQL connection details for Keycloak"
  recovery_window_in_days = var.secret_recovery_window_days
  kms_key_id              = var.kms_key_arn != "" ? var.kms_key_arn : null

  tags = { Name = "${local.name_prefix}-db-secret" }
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id

  # jsonencode turns this map into proper JSON, so the EC2 script can read
  # single fields with:  jq -r .password
  secret_string = jsonencode({
    engine   = "postgres"
    host     = aws_db_instance.main.address
    port     = aws_db_instance.main.port
    dbname   = aws_db_instance.main.db_name
    username = aws_db_instance.main.username
    password = random_password.db.result
    jdbc_url = "jdbc:postgresql://${aws_db_instance.main.address}:${aws_db_instance.main.port}/${aws_db_instance.main.db_name}"
  })
}
