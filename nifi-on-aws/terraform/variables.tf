variable "project" {
  description = "Prefix for every resource name"
  type        = string
  default     = "nifi-demo"
  validation {
    condition     = can(regex("^[a-z0-9-]{3,24}$", var.project))
    error_message = "Lowercase letters, digits and hyphens, 3-24 characters."
  }
}

variable "aws_region" {
  type    = string
  default = "eu-west-1"
}

# ---------------------------------------------------------------------------
variable "node_count" {
  description = "1 = simple single node (no ALB, no ZooKeeper). 3 = real cluster."
  type        = number
  default     = 1
  validation {
    condition     = var.node_count == 1 || (var.node_count >= 3 && var.node_count % 2 == 1)
    error_message = "Use 1, or an odd number >= 3 so cluster elections cannot tie."
  }
}

variable "nifi_instance_type" {
  type    = string
  default = "t3.large"
}

variable "zk_instance_type" {
  type    = string
  default = "t3.small"
}

# ---------------------------------------------------------------------------
variable "nifi_version" {
  description = "NiFi image tag. 1.x is end-of-life; 2.7.2 and below are affected by CVE-2026-25903."
  type        = string
  default     = "2.10.0"
  validation {
    # Blocks the two genuinely dangerous choices at plan time rather than
    # letting someone discover them in production.
    condition     = can(regex("^2\\.(([89])|([1-9][0-9]+))\\.", var.nifi_version))
    error_message = "Use NiFi 2.8.0 or later. 1.x is EOL and <=2.7.2 has a known authorisation bypass."
  }
}

variable "artifactory_registry" {
  description = "Artifactory Docker registry host, e.g. mycompany.jfrog.io"
  type        = string
}

variable "artifactory_repo" {
  type    = string
  default = "docker-remote"
}

variable "artifactory_user" {
  type    = string
  default = "svc-nifi-puller"
}

variable "artifactory_password" {
  description = "Pull credential. Pass via TF_VAR_artifactory_password, never in a .tfvars file you commit."
  type        = string
  sensitive   = true
}

variable "nifi_sensitive_props_key" {
  description = <<-TXT
    Encrypts sensitive values INSIDE your flows. Must be identical on every
    node and must survive upgrades. If empty, one is generated - but then it
    lives only in state, so copy it out and store it properly.
  TXT
  type      = string
  sensitive = true
  default   = ""
}

# ---------------------------------------------------------------------------
variable "data_volume_gb" {
  description = "Size of the persistent EBS volume holding every NiFi repository"
  type        = number
  default     = 100
}

variable "root_volume_gb" {
  type    = number
  default = 30
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "allowed_cidr" {
  description = "Who may reach the load balancer. Your IP, not 0.0.0.0/0."
  type        = string
  validation {
    condition     = var.allowed_cidr != "0.0.0.0/0"
    error_message = "Refusing 0.0.0.0/0. Put your own address here: curl -s https://checkip.amazonaws.com"
  }
}

variable "acm_certificate_arn" {
  description = "Required when node_count > 1. MUST be in the same region as the load balancer."
  type        = string
  default     = ""
}

variable "hosted_zone_id" {
  type    = string
  default = ""
}

variable "nifi_hostname" {
  description = "e.g. nifi.example.com. Optional."
  type        = string
  default     = ""
}

variable "log_retention_days" {
  type    = number
  default = 30
}
