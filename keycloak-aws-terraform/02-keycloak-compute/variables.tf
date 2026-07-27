# ---------------------------------------------------------------------------
# variables.tf  -  knobs for stack 2 (the Keycloak servers).
# ---------------------------------------------------------------------------

variable "aws_region" {
  description = "Must be the same region as stack 1."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Must match stack 1 exactly - it is how we find the SSM values."
  type        = string
  default     = "keycloak"
}

variable "environment" {
  description = "Must match stack 1 exactly."
  type        = string
  default     = "dev"
}

variable "extra_tags" {
  description = "Extra tags for every resource."
  type        = map(string)
  default     = {}
}

# --------------------------- Keycloak image --------------------------------

variable "artifactory_registry" {
  description = "Artifactory Docker registry host, e.g. mycompany.jfrog.io or artifactory.mycompany.com:5000."
  type        = string
  default     = "mycompany.jfrog.io"
}

variable "artifactory_repo_path" {
  description = "Repository path inside Artifactory that mirrors the Keycloak image."
  type        = string
  default     = "docker-remote/keycloak/keycloak"
}

variable "keycloak_image_tag" {
  description = "Keycloak version tag to run. Pin a real version - 'latest' makes rebuilds unpredictable."
  type        = string
  default     = "26.2"
}

variable "artifactory_auth_enabled" {
  description = "true = run 'docker login' against Artifactory using a secret before pulling. false = anonymous pull."
  type        = bool
  default     = true
}

variable "artifactory_secret_name" {
  description = "Secrets Manager secret holding {\"username\":\"...\",\"password\":\"...\"} for Artifactory. Created by you, not by Terraform."
  type        = string
  default     = "keycloak/artifactory-credentials"
}

# --------------------------- Keycloak settings ------------------------------

variable "keycloak_admin_username" {
  description = "Bootstrap admin user for the Keycloak console."
  type        = string
  default     = "admin"
}

variable "keycloak_admin_password" {
  description = "Bootstrap admin password. admin/admin is for demos ONLY - change it before anyone else can reach the URL."
  type        = string
  default     = "admin"
  sensitive   = true
}

variable "keycloak_http_port" {
  description = "Port Keycloak serves the application on."
  type        = number
  default     = 8080
}

variable "keycloak_management_port" {
  description = "Port Keycloak serves health and metrics on (Keycloak 25 and newer)."
  type        = number
  default     = 9000
}

variable "keycloak_hostname" {
  description = "Public hostname clients will use. Leave empty to let Keycloak read it from the load balancer headers."
  type        = string
  default     = ""
}

variable "keycloak_cache_stack" {
  description = "Empty = each server keeps its own cache (needs sticky sessions). 'jdbc-ping' = the two servers form a real cluster through the database (Keycloak 26.2+)."
  type        = string
  default     = ""
}

variable "keycloak_extra_env" {
  description = "Any extra KC_* environment variables to pass to the container."
  type        = map(string)
  default     = {}
}

variable "keycloak_java_opts" {
  description = "JVM memory settings for the container."
  type        = string
  default     = "-XX:MaxRAMPercentage=70"
}

# ------------------------------- Compute -----------------------------------

variable "instance_type" {
  description = "EC2 size. t3.small (2 GB RAM) is the realistic minimum for Keycloak."
  type        = string
  default     = "t3.small"
}

variable "cpu_architecture" {
  description = "x86_64 or arm64. arm64 with a t4g instance type is about 20 percent cheaper."
  type        = string
  default     = "x86_64"

  validation {
    condition     = contains(["x86_64", "arm64"], var.cpu_architecture)
    error_message = "cpu_architecture must be x86_64 or arm64."
  }
}

variable "root_volume_size" {
  description = "Disk size in GB for each server."
  type        = number
  default     = 20
}

variable "asg_min_size" {
  description = "Never run fewer servers than this."
  type        = number
  default     = 2
}

variable "asg_max_size" {
  description = "Never run more servers than this."
  type        = number
  default     = 4
}

variable "asg_desired_capacity" {
  description = "How many servers to run right now. The task asks for 2."
  type        = number
  default     = 2
}

variable "asg_health_check_type" {
  description = "EC2 = only checks the machine is alive. ELB = also checks Keycloak answers. Switch to ELB after stack 3 exists."
  type        = string
  default     = "EC2"

  validation {
    condition     = contains(["EC2", "ELB"], var.asg_health_check_type)
    error_message = "asg_health_check_type must be EC2 or ELB."
  }
}

variable "asg_health_check_grace_period" {
  description = "Seconds to wait after boot before health checks count. Keycloak needs time to start and migrate the database."
  type        = number
  default     = 300
}

variable "enable_instance_refresh" {
  description = "true = when the launch template changes, replace instances one at a time automatically."
  type        = bool
  default     = true
}

variable "use_spot_instances" {
  description = "true = use Spot capacity (up to 70 percent cheaper, can be reclaimed with 2 minutes notice)."
  type        = bool
  default     = false
}

variable "enable_detailed_monitoring" {
  description = "1-minute CloudWatch metrics instead of 5-minute. Small extra cost."
  type        = bool
  default     = false
}

variable "enable_cloudwatch_logs" {
  description = "Ship the Keycloak container log to CloudWatch Logs so you can debug without logging in."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "How long to keep Keycloak logs in CloudWatch."
  type        = number
  default     = 14
}

variable "enable_cpu_autoscaling" {
  description = "Add a target-tracking policy that scales on average CPU."
  type        = bool
  default     = false
}

variable "cpu_target_percent" {
  description = "Average CPU percent the autoscaler aims for."
  type        = number
  default     = 60
}
