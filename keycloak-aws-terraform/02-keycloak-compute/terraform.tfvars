# ===========================================================================
# terraform.tfvars  -  STACK 2 (Keycloak servers)
#
# IMPORTANT: aws_region, project_name and environment MUST match stack 1.
# That is how stack 2 finds stack 1's values in Parameter Store.
# ===========================================================================

aws_region   = "us-east-1"
project_name = "keycloak"
environment  = "dev"

extra_tags = {
  Owner      = "platform-team"
  CostCenter = "sandbox"
}

# --- Where the Docker image comes from ------------------------------------
# Final image name is: registry / repo_path : tag
#   mycompany.jfrog.io/docker-remote/keycloak/keycloak:26.2
# Change these three lines to point at YOUR Artifactory.
artifactory_registry  = "mycompany.jfrog.io"
artifactory_repo_path = "docker-remote/keycloak/keycloak"
keycloak_image_tag    = "26.2"

# Artifactory login. Create this secret yourself FIRST:
#   aws secretsmanager create-secret \
#     --name keycloak/artifactory-credentials \
#     --secret-string '{"username":"svc-user","password":"my-api-token"}'
# Set artifactory_auth_enabled = false if your repo allows anonymous pulls.
artifactory_auth_enabled = true
artifactory_secret_name  = "keycloak/artifactory-credentials"

# --- Keycloak settings ----------------------------------------------------
# admin/admin is requested for this demo. It is fine while the load balancer
# does not exist yet. CHANGE IT the moment stack 3 is applied.
keycloak_admin_username = "admin"
keycloak_admin_password = "admin"

keycloak_http_port       = 8080
keycloak_management_port = 9000

# Empty = one cache per server, so the load balancer needs sticky sessions.
# Set to "jdbc-ping" on Keycloak 26.2+ to make the two servers a real cluster.
keycloak_cache_stack = ""

# Leave empty and Keycloak reads its public address from the load balancer.
keycloak_hostname = ""

keycloak_java_opts = "-XX:MaxRAMPercentage=70"

keycloak_extra_env = {
  # KC_LOG_LEVEL = "INFO"
}

# --- Servers --------------------------------------------------------------
instance_type    = "t3.small" # 2 GB RAM - the realistic minimum
cpu_architecture = "x86_64"   # use "arm64" + t4g.small to save ~20 percent
root_volume_size = 20

asg_min_size         = 2
asg_max_size         = 4
asg_desired_capacity = 2

# Start with EC2. After stack 3 exists, change to "ELB" and re-apply so a
# hung Keycloak (not just a dead machine) also gets replaced.
asg_health_check_type         = "EC2"
asg_health_check_grace_period = 300

enable_instance_refresh = true
use_spot_instances      = false

enable_cloudwatch_logs = true
log_retention_days     = 14

enable_cpu_autoscaling = false
cpu_target_percent     = 60
