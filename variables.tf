variable "aws_region" {
  description = "AWS region where resources will be created"
  type        = string
  default     = "us-east-1"
}

variable "identifier" {
  description = "Unique identifier for the RDS instance"
  type        = string
  default     = "postgres-db"
}

variable "engine_version" {
  description = "PostgreSQL engine version"
  type        = string
  default     = "16.4"
}

variable "instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro"
}

variable "allocated_storage" {
  description = "Allocated storage in GB"
  type        = number
  default     = 20
}

variable "max_allocated_storage" {
  description = "Upper limit for storage autoscaling in GB. Set equal to allocated_storage to disable autoscaling."
  type        = number
  default     = 100
}

variable "storage_type" {
  description = "Storage type (gp2, gp3, io1)"
  type        = string
  default     = "gp3"
}

variable "db_name" {
  description = "Name of the default database to create"
  type        = string
  default     = "appdb"
}

variable "db_username" {
  description = "Master username for the database"
  type        = string
  default     = "dbadmin"
}

variable "db_password" {
  description = "Master password for the database. Do not hardcode in tfvars committed to version control - pass via TF_VAR_db_password env var, a CI secret, or a secrets manager."
  type        = string
  sensitive   = true
}

variable "subnet_ids" {
  description = "List of existing subnet IDs to use for the DB subnet group (should span at least 2 Availability Zones)"
  type        = list(string)
}

variable "vpc_security_group_ids" {
  description = "List of existing security group IDs to attach to the RDS instance"
  type        = list(string)
}

variable "multi_az" {
  description = "Whether to deploy a Multi-AZ standby instance"
  type        = bool
  default     = false
}

variable "publicly_accessible" {
  description = "Whether the RDS instance should be publicly accessible"
  type        = bool
  default     = false
}

variable "backup_retention_period" {
  description = "Number of days to retain automated backups"
  type        = number
  default     = 7
}

variable "backup_window" {
  description = "Preferred backup window (UTC)"
  type        = string
  default     = "03:00-04:00"
}

variable "maintenance_window" {
  description = "Preferred maintenance window (UTC)"
  type        = string
  default     = "mon:04:30-mon:05:30"
}

variable "skip_final_snapshot" {
  description = "Whether to skip taking a final snapshot when the instance is destroyed"
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "Whether to enable deletion protection on the instance"
  type        = bool
  default     = true
}

variable "apply_immediately" {
  description = "Whether modifications are applied immediately instead of during the next maintenance window"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
