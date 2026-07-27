# ---------------------------------------------------------------------------
# outputs.tf  -  values printed after "terraform apply" so a human can see
#                what was built. Secrets are never printed.
# ---------------------------------------------------------------------------

output "vpc_id" {
  description = "Id of the VPC."
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "IP range of the VPC."
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnets (load balancer and NAT live here)."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnets (database and Keycloak servers live here)."
  value       = aws_subnet.private[*].id
}

output "database_security_group_id" {
  description = "Firewall attached to the database."
  value       = aws_security_group.database.id
}

output "database_endpoint" {
  description = "Private DNS name of the PostgreSQL server."
  value       = aws_db_instance.main.address
}

output "database_port" {
  description = "PostgreSQL port."
  value       = aws_db_instance.main.port
}

output "database_name" {
  description = "Name of the Keycloak database."
  value       = aws_db_instance.main.db_name
}

output "database_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the credentials."
  value       = aws_secretsmanager_secret.db.arn
}

output "database_secret_name" {
  description = "Friendly name of the secret. Read it with: aws secretsmanager get-secret-value --secret-id <name>"
  value       = aws_secretsmanager_secret.db.name
}

output "nat_gateway_ids" {
  description = "NAT Gateways created (empty if disabled)."
  value       = aws_nat_gateway.main[*].id
}

output "ssm_prefix" {
  description = "Where stacks 2 and 3 look for these values."
  value       = local.ssm_prefix
}
