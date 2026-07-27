# ===========================================================================
# terraform.tfvars  -  STACK 3 (public access / load balancer)
#
# IMPORTANT: aws_region, project_name and environment MUST match stacks 1-2.
# ===========================================================================

aws_region   = "us-east-1"
project_name = "keycloak"
environment  = "dev"

extra_tags = {
  Owner      = "platform-team"
  CostCenter = "sandbox"
}

# --- Who can reach it -----------------------------------------------------
# 0.0.0.0/0 = the whole internet. While the admin password is still admin/admin
# you should put YOUR OWN IP here instead, for example ["203.0.113.25/32"].
allowed_cidr_blocks = ["0.0.0.0/0"]

# --- HTTPS ----------------------------------------------------------------
# Off by default so the template works with zero prerequisites.
# To turn it on: request a free ACM certificate for your domain, paste the ARN
# here, set enable_https = true, then point a CNAME at the alb_dns_name output.
enable_https           = false
acm_certificate_arn    = ""
redirect_http_to_https = true

# --- Load balancer behaviour ----------------------------------------------
internal                   = false
enable_deletion_protection = false
idle_timeout               = 60
enable_http2               = true
drop_invalid_header_fields = true

# --- Health checks --------------------------------------------------------
# Keycloak 25+ serves health on the management port (9000), not on 8080.
health_check_path     = "/health/ready"
health_check_interval = 30
health_check_timeout  = 5
healthy_threshold     = 2
unhealthy_threshold   = 3
deregistration_delay  = 30

# --- Sessions -------------------------------------------------------------
# Keep this true unless you set keycloak_cache_stack = "jdbc-ping" in stack 2.
# Without it, a login started on server A can fail on server B.
enable_stickiness   = true
stickiness_duration = 3600

# --- Access logs ----------------------------------------------------------
enable_access_logs = false
access_logs_bucket = ""

# --- Wiring ---------------------------------------------------------------
attach_asg = true
