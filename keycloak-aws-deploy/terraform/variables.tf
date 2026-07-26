# ---------------------------------------------------------------------------
# Core
# ---------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short name used as a prefix on every resource"
  type        = string
  default     = "keycloak"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,20}$", var.project_name))
    error_message = "Lowercase letters, digits and hyphens; 3-21 characters."
  }
}

variable "environment" {
  description = "dev, staging, or prod"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Must be dev, staging, or prod."
  }
}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "IP range for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zone_count" {
  description = "How many AZs to spread across. Minimum 2 for fault tolerance."
  type        = number
  default     = 2

  validation {
    condition     = var.availability_zone_count >= 2
    error_message = "You need at least 2 AZs for fault tolerance."
  }
}

variable "single_nat_gateway" {
  description = "true = one shared NAT (~$35/mo, less resilient). false = one per AZ (~$70/mo)."
  type        = bool
  default     = false
}

variable "enable_flow_logs" {
  description = "VPC Flow Logs. Invaluable for debugging connectivity; small CloudWatch cost."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Keycloak / Artifactory
# ---------------------------------------------------------------------------

variable "keycloak_image" {
  description = "Full Artifactory image path INCLUDING the version tag"
  type        = string

  validation {
    condition     = can(regex(":[^:/]+$", var.keycloak_image)) && !can(regex(":latest$", var.keycloak_image))
    error_message = "Pin an explicit version tag. Never deploy ':latest' - two instances launched an hour apart could run different Keycloak versions against the same database."
  }
}

variable "artifactory_host" {
  description = "Artifactory registry hostname, e.g. mycompany.jfrog.io"
  type        = string
}

variable "artifactory_username" {
  description = "Service account username for pulling images"
  type        = string
}

variable "artifactory_token" {
  description = "Artifactory access token. Prefer the TF_VAR_artifactory_token env var."
  type        = string
  sensitive   = true
}

# ---------------------------------------------------------------------------
# Sizing
# ---------------------------------------------------------------------------

variable "instance_type" {
  description = "EC2 size for Keycloak nodes. Below 2GB RAM the JVM struggles."
  type        = string
  default     = "t3.medium"
}

variable "asg_min_size" {
  description = "Minimum instances. Never below 2 in production."
  type        = number
  default     = 2

  validation {
    condition     = var.asg_min_size >= 1
    error_message = "Must be at least 1. Use 2 or more for real fault tolerance."
  }
}

variable "asg_max_size" {
  description = "Ceiling on instance count, and therefore on the bill"
  type        = number
  default     = 6
}

variable "root_volume_size" {
  description = "Root EBS volume size in GB"
  type        = number
  default     = 30
}

# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------

variable "db_instance_class" {
  type    = string
  default = "db.t3.medium"
}

variable "db_allocated_storage" {
  type    = number
  default = 20
}

variable "db_engine_version" {
  description = "PostgreSQL major version. Must match db_parameter_group_family."
  type        = string
  default     = "16"
}

variable "db_parameter_group_family" {
  type    = string
  default = "postgres16"
}

variable "db_multi_az" {
  description = "Synchronous standby in a second AZ. Roughly doubles DB cost. THE fault-tolerance switch."
  type        = bool
  default     = true
}

variable "db_backup_retention_days" {
  description = "Days of automated backups, enabling point-in-time recovery"
  type        = number
  default     = 7

  validation {
    condition     = var.db_backup_retention_days >= 1
    error_message = "Never disable backups."
  }
}

variable "db_pool_max_size" {
  description = "Max DB connections PER Keycloak node. Watch the math: this x asg_max_size must stay well under the DB's max_connections."
  type        = number
  default     = 20
}

# ---------------------------------------------------------------------------
# DNS / TLS
# ---------------------------------------------------------------------------

variable "domain_name" {
  description = "Public hostname users will visit, e.g. auth.example.com"
  type        = string
}

variable "route53_zone_name" {
  description = "Hosted zone, e.g. example.com. Leave empty to skip DNS."
  type        = string
  default     = ""
}

variable "acm_certificate_arn" {
  description = "ACM cert ARN. MUST be in the same region as the ALB."
  type        = string
}

# ---------------------------------------------------------------------------
# Safety switches - see docs/DESTROY.md
# ---------------------------------------------------------------------------

variable "enable_deletion_protection" {
  description = "Blocks accidental deletion of the DB and ALB. Set false before destroying."
  type        = bool
  default     = true
}

variable "db_skip_final_snapshot" {
  description = "true = NO backup taken on destroy. Never true in prod."
  type        = bool
  default     = false
}

variable "log_retention_days" {
  description = "CloudWatch retention. Logs default to never expiring, which costs money forever."
  type        = number
  default     = 14
}
