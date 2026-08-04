output "db_instance_id" {
  description = "RDS instance ID"
  value       = aws_db_instance.postgres.id
}

output "db_instance_arn" {
  description = "RDS instance ARN"
  value       = aws_db_instance.postgres.arn
}

output "db_instance_endpoint" {
  description = "Connection endpoint in host:port form"
  value       = aws_db_instance.postgres.endpoint
}

output "db_instance_address" {
  description = "Hostname of the RDS instance (no port)"
  value       = aws_db_instance.postgres.address
}

output "db_instance_port" {
  description = "Port the database listens on"
  value       = aws_db_instance.postgres.port
}

output "db_name" {
  description = "Name of the default database created on the instance"
  value       = aws_db_instance.postgres.db_name
}

output "db_subnet_group_name" {
  description = "Name of the DB subnet group created from existing subnets"
  value       = aws_db_subnet_group.this.name
}
