# ---------------------------------------------------------------------------
# variables.tf  -  knobs for stack 3 (the public front door).
# ---------------------------------------------------------------------------

variable "aws_region" {
  description = "Must match stacks 1 and 2."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Must match stacks 1 and 2."
  type        = string
  default     = "keycloak"
}

variable "environment" {
  description = "Must match stacks 1 and 2."
  type        = string
  default     = "dev"
}

variable "extra_tags" {
  description = "Extra tags for every resource."
  type        = map(string)
  default     = {}
}

# ------------------------------ Access control ------------------------------

variable "allowed_cidr_blocks" {
  description = "Who may reach the load balancer. 0.0.0.0/0 means the whole internet. Narrow this to your office IP for a demo."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# --------------------------------- HTTPS ------------------------------------

variable "enable_https" {
  description = "true = add a TLS listener on 443. Requires acm_certificate_arn."
  type        = bool
  default     = false
}

variable "acm_certificate_arn" {
  description = "ARN of an ACM certificate in the same region. Free from AWS if you own a domain."
  type        = string
  default     = ""

  validation {
    condition     = var.acm_certificate_arn == "" || can(regex("^arn:aws[a-z-]*:acm:", var.acm_certificate_arn))
    error_message = "acm_certificate_arn must be empty or a valid ACM ARN."
  }
}

variable "redirect_http_to_https" {
  description = "When HTTPS is on, send plain HTTP visitors to HTTPS instead of serving them."
  type        = bool
  default     = true
}

variable "ssl_policy" {
  description = "TLS policy for the HTTPS listener."
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-2-2021-06"
}

# ------------------------------ Load balancer -------------------------------

variable "internal" {
  description = "true = private load balancer (no internet access at all)."
  type        = bool
  default     = false
}

variable "enable_deletion_protection" {
  description = "true stops anyone deleting the load balancer by accident."
  type        = bool
  default     = false
}

variable "idle_timeout" {
  description = "Seconds a connection can sit idle before the load balancer closes it."
  type        = number
  default     = 60
}

variable "enable_http2" {
  description = "Allow HTTP/2 between clients and the load balancer."
  type        = bool
  default     = true
}

variable "drop_invalid_header_fields" {
  description = "Throw away malformed headers before they reach Keycloak. Recommended."
  type        = bool
  default     = true
}

# ------------------------------ Target group --------------------------------

variable "health_check_path" {
  description = "URL the load balancer calls to decide if a server is healthy."
  type        = string
  default     = "/health/ready"
}

variable "health_check_interval" {
  description = "Seconds between health checks."
  type        = number
  default     = 30
}

variable "health_check_timeout" {
  description = "Seconds to wait for a health check answer."
  type        = number
  default     = 5
}

variable "healthy_threshold" {
  description = "How many good checks in a row before a server is called healthy."
  type        = number
  default     = 2
}

variable "unhealthy_threshold" {
  description = "How many bad checks in a row before a server is taken out."
  type        = number
  default     = 3
}

variable "deregistration_delay" {
  description = "Seconds to let existing requests finish before removing a server."
  type        = number
  default     = 30
}

variable "enable_stickiness" {
  description = "Send the same visitor back to the same server. REQUIRED when keycloak_cache_stack is empty in stack 2."
  type        = bool
  default     = true
}

variable "stickiness_duration" {
  description = "Seconds the stickiness cookie lasts."
  type        = number
  default     = 3600
}

# ------------------------------ Access logs ---------------------------------

variable "enable_access_logs" {
  description = "Write every request to an S3 bucket. Costs a few cents, very useful for audits."
  type        = bool
  default     = false
}

variable "access_logs_bucket" {
  description = "Existing S3 bucket name for access logs. Only used when enable_access_logs is true."
  type        = string
  default     = ""
}

# -------------------------------- Wiring ------------------------------------

variable "attach_asg" {
  description = "true = attach stack 2's Auto Scaling group to this target group. Set false if you want the load balancer with no backends yet."
  type        = bool
  default     = true
}
