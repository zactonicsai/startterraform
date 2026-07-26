# Cheapest sensible dev environment: ~$120/month instead of ~$300.
# Do NOT use these settings for anything real.
environment                = "dev"
single_nat_gateway         = true    # one NAT instead of two
db_multi_az                = false   # no standby - saves ~$65/mo
db_instance_class          = "db.t3.micro"
db_backup_retention_days   = 1
asg_min_size               = 1       # accepts an outage window on failure
asg_max_size               = 2
instance_type              = "t3.small"
enable_flow_logs           = false
enable_deletion_protection = false   # so destroy is not a fight
log_retention_days         = 7
