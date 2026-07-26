# Production. Also uncomment prevent_destroy in rds.tf.
environment                = "prod"
availability_zone_count    = 3
single_nat_gateway         = false
db_multi_az                = true
db_instance_class          = "db.m6g.large"   # Graviton: ~20% cheaper
db_allocated_storage       = 100
db_backup_retention_days   = 30
asg_min_size               = 4                # 2 per AZ: survives an AZ loss
asg_max_size               = 12
instance_type              = "m6g.large"      # verify your image is arm64
enable_flow_logs           = true
enable_deletion_protection = true
db_skip_final_snapshot     = false
log_retention_days         = 90
