# ---------------------------------------------------------------------------
# ssm_exports.tf
#
# How do stacks 2 and 3 learn the VPC id, subnet ids and secret name?
# We write them into SSM Parameter Store (a free key/value store in AWS).
# Later stacks simply READ these keys.
#
# Why not read stack 1's state file directly? Because that couples the stacks
# together and forces everyone to share a backend. Parameter Store keeps each
# stack independent, which is exactly what "destroy only part of it" needs.
# ---------------------------------------------------------------------------

resource "aws_ssm_parameter" "vpc_id" {
  name  = "${local.ssm_prefix}/network/vpc_id"
  type  = "String"
  value = aws_vpc.main.id
}

resource "aws_ssm_parameter" "vpc_cidr" {
  name  = "${local.ssm_prefix}/network/vpc_cidr"
  type  = "String"
  value = aws_vpc.main.cidr_block
}

resource "aws_ssm_parameter" "private_subnet_ids" {
  name  = "${local.ssm_prefix}/network/private_subnet_ids"
  type  = "StringList"
  value = join(",", aws_subnet.private[*].id)
}

resource "aws_ssm_parameter" "public_subnet_ids" {
  name  = "${local.ssm_prefix}/network/public_subnet_ids"
  type  = "StringList"
  value = join(",", aws_subnet.public[*].id)
}

resource "aws_ssm_parameter" "db_security_group_id" {
  name  = "${local.ssm_prefix}/database/security_group_id"
  type  = "String"
  value = aws_security_group.database.id
}

resource "aws_ssm_parameter" "db_secret_arn" {
  name  = "${local.ssm_prefix}/database/secret_arn"
  type  = "String"
  value = aws_secretsmanager_secret.db.arn
}

resource "aws_ssm_parameter" "db_secret_name" {
  name  = "${local.ssm_prefix}/database/secret_name"
  type  = "String"
  value = aws_secretsmanager_secret.db.name
}

resource "aws_ssm_parameter" "db_port" {
  name  = "${local.ssm_prefix}/database/port"
  type  = "String"
  value = tostring(aws_db_instance.main.port)
}

resource "aws_ssm_parameter" "db_endpoint" {
  name  = "${local.ssm_prefix}/database/endpoint"
  type  = "String"
  value = aws_db_instance.main.address
}
