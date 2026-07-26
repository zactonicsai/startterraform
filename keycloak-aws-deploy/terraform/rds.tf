resource "aws_db_subnet_group" "main" {
  name_prefix = "${local.name}-db-"
  subnet_ids  = [for k in local.data_subnet_keys : aws_subnet.this[k].id]

  tags = { Name = "${local.name}-db-subnets" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_parameter_group" "main" {
  name_prefix = "${local.name}-pg-"
  family      = var.db_parameter_group_family

  # Log any query taking longer than 1 second
  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }

  # Encryption in transit: refuse non-TLS connections
  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# THE most important resource in the stack. Everything else can be rebuilt
# from this code; this holds all the users, realms, clients and credentials.
# ---------------------------------------------------------------------------

resource "aws_db_instance" "main" {
  identifier_prefix = "${local.name}-"

  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  # db_name creates an empty database inside the server. Without it,
  # Keycloak's first connection fails.
  db_name  = "keycloak"
  username = "kcadmin"
  password = random_password.db.result
  port     = 5432

  allocated_storage = var.db_allocated_storage
  # Storage autoscaling: if it fills up, AWS grows it instead of breaking.
  max_allocated_storage = var.db_allocated_storage * 5
  storage_type          = "gp3"
  # Cannot be enabled later without a snapshot-and-restore. Always on now.
  storage_encrypted = true

  # THE fault-tolerance switch. Synchronous standby in another AZ,
  # automatic failover in 60-120 seconds with no data loss.
  # The standby is NOT readable - you are buying survivability, not speed.
  multi_az = var.db_multi_az

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  parameter_group_name   = aws_db_parameter_group.main.name

  # Enables point-in-time recovery: restore to any second in the window.
  backup_retention_period = var.db_backup_retention_days
  backup_window           = "03:00-04:00" # UTC
  maintenance_window      = "sun:04:30-sun:05:30"
  copy_tags_to_snapshot   = true

  auto_minor_version_upgrade = true
  apply_immediately          = var.environment != "prod"

  performance_insights_enabled     = true
  enabled_cloudwatch_logs_exports  = ["postgresql", "upgrade"]

  # ---- Safety ----
  deletion_protection       = var.enable_deletion_protection
  skip_final_snapshot       = var.db_skip_final_snapshot
  final_snapshot_identifier = var.db_skip_final_snapshot ? null : "${local.name}-final-${formatdate("YYYYMMDD-hhmmss", timestamp())}"

  lifecycle {
    ignore_changes = [
      # timestamp() changes on EVERY plan. Without ignoring it you would see
      # a diff every time, which trains you to ignore plan output - a
      # genuinely dangerous habit.
      final_snapshot_identifier,
      # auto_minor_version_upgrade means AWS may bump 16.3 -> 16.4 on its
      # own. Ignoring this stops Terraform trying to downgrade it back.
      engine_version,
    ]

    # ---- RECOMMENDED FOR PRODUCTION ----
    # Uncomment and Terraform will REFUSE to destroy the database, even with
    # `terraform destroy`. You then have to edit this file and remove the
    # line - deliberate friction that has saved a lot of production data.
    #
    # The downside: it also blocks `terraform destroy` for the whole stack.
    # Use it in prod, leave it off in dev.
    #
    # prevent_destroy = true
  }

  tags = { Name = "${local.name}-db" }
}
