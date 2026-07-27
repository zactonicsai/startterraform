# ---------------------------------------------------------------------------
# variables.tf  -  every "knob" you can turn for stack 1.
# Real values live in terraform.tfvars so nobody has to edit the code.
# ---------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region where everything is built (example: us-east-1)."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short name used to prefix every resource. Lowercase letters, numbers and dashes only."
  type        = string
  default     = "keycloak"

  validation {
    condition     = can(regex("^[a-z0-9-]{2,20}$", var.project_name))
    error_message = "project_name must be 2-20 characters of lowercase letters, numbers or dashes."
  }
}

variable "environment" {
  description = "Environment name (dev, test, prod). Lets you run the same template many times."
  type        = string
  default     = "dev"

  validation {
    condition     = can(regex("^[a-z0-9]{2,10}$", var.environment))
    error_message = "environment must be 2-10 lowercase letters or numbers."
  }
}

variable "extra_tags" {
  description = "Any extra tags you want on every resource (cost centre, owner, ...)."
  type        = map(string)
  default     = {}
}

# ----------------------------- Networking ----------------------------------

variable "vpc_cidr" {
  description = "The whole private IP range for the VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "availability_zone_count" {
  description = "How many Availability Zones to spread subnets across. 2 is the minimum for RDS and ALB."
  type        = number
  default     = 2

  validation {
    condition     = var.availability_zone_count >= 2 && var.availability_zone_count <= 4
    error_message = "availability_zone_count must be between 2 and 4."
  }
}

variable "public_subnet_newbits" {
  description = "How many extra bits to add to the VPC mask for public subnets. 8 turns a /16 into /24s."
  type        = number
  default     = 8
}

variable "private_subnet_newbits" {
  description = "How many extra bits to add to the VPC mask for private subnets."
  type        = number
  default     = 8
}

variable "enable_nat_gateway" {
  description = "Create NAT Gateway(s) so private instances can reach the internet (needed to pull the Docker image). Costs about USD 32 per month each."
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "true = one shared NAT Gateway (cheapest). false = one per AZ (more resilient, more expensive)."
  type        = bool
  default     = true
}

variable "enable_vpc_flow_logs" {
  description = "Send VPC network logs to CloudWatch. Great for security, costs a little extra."
  type        = bool
  default     = false
}

variable "flow_log_retention_days" {
  description = "How many days to keep VPC flow logs."
  type        = number
  default     = 14
}

# ------------------------------- Database ----------------------------------

variable "db_engine_version" {
  description = "PostgreSQL major version. Leaving it as a major number lets AWS pick the newest minor version."
  type        = string
  default     = "16"
}

variable "db_instance_class" {
  description = "Size of the database server. db.t4g.micro is the cheapest Graviton option."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_allocated_storage" {
  description = "Disk size in GB for the database."
  type        = number
  default     = 20
}

variable "db_max_allocated_storage" {
  description = "Upper limit in GB for storage autoscaling. Set to 0 to disable autoscaling."
  type        = number
  default     = 100
}

variable "db_name" {
  description = "Name of the database Keycloak will use."
  type        = string
  default     = "keycloak"
}

variable "db_username" {
  description = "Master username for PostgreSQL. Cannot be 'postgres', 'admin' or other reserved words."
  type        = string
  default     = "kcadmin"
}

variable "db_port" {
  description = "PostgreSQL port."
  type        = number
  default     = 5432
}

variable "db_multi_az" {
  description = "true = a standby copy in another AZ (high availability, roughly double cost)."
  type        = bool
  default     = false
}

variable "db_backup_retention_days" {
  description = "How many days of automatic backups to keep. 0 turns backups off (not recommended)."
  type        = number
  default     = 7
}

variable "db_deletion_protection" {
  description = "true stops anyone (including Terraform) from deleting the database by accident."
  type        = bool
  default     = false
}

variable "db_skip_final_snapshot" {
  description = "true = do not take a last backup when destroying. Handy for dev, dangerous for prod."
  type        = bool
  default     = true
}

variable "db_performance_insights_enabled" {
  description = "Enable RDS Performance Insights. Free for 7 days retention on most classes."
  type        = bool
  default     = false
}

variable "db_apply_immediately" {
  description = "true = apply database changes right away instead of the next maintenance window."
  type        = bool
  default     = true
}

# -------------------------------- Secrets ----------------------------------

variable "secret_recovery_window_days" {
  description = "Days AWS keeps a deleted secret before really deleting it. 0 = delete instantly, which makes destroy/recreate cycles painless in dev."
  type        = number
  default     = 0

  validation {
    condition     = var.secret_recovery_window_days == 0 || (var.secret_recovery_window_days >= 7 && var.secret_recovery_window_days <= 30)
    error_message = "secret_recovery_window_days must be 0, or between 7 and 30."
  }
}

variable "db_password_length" {
  description = "Length of the generated database password."
  type        = number
  default     = 32
}

variable "kms_key_arn" {
  description = "Optional customer managed KMS key ARN for RDS and Secrets Manager encryption. Empty string uses the free AWS managed key."
  type        = string
  default     = ""
}
