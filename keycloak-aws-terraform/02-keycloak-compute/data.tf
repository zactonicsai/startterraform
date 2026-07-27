# ---------------------------------------------------------------------------
# data.tf  -  "data" blocks LOOK UP things that already exist.
#             Here we read the values stack 1 published into Parameter Store.
#             If stack 1 has not been applied yet, these lookups fail with a
#             clear "ParameterNotFound" error - that is the intended guard rail.
# ---------------------------------------------------------------------------

locals {
  name_prefix = "${var.project_name}-${var.environment}"
  ssm_prefix  = "/${var.project_name}/${var.environment}"

  # Full image reference, e.g. mycompany.jfrog.io/docker-remote/keycloak/keycloak:26.2
  keycloak_image = "${var.artifactory_registry}/${var.artifactory_repo_path}:${var.keycloak_image_tag}"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_ssm_parameter" "vpc_id" {
  name = "${local.ssm_prefix}/network/vpc_id"
}

data "aws_ssm_parameter" "vpc_cidr" {
  name = "${local.ssm_prefix}/network/vpc_cidr"
}

data "aws_ssm_parameter" "private_subnet_ids" {
  name = "${local.ssm_prefix}/network/private_subnet_ids"
}

data "aws_ssm_parameter" "db_security_group_id" {
  name = "${local.ssm_prefix}/database/security_group_id"
}

data "aws_ssm_parameter" "db_secret_arn" {
  name = "${local.ssm_prefix}/database/secret_arn"
}

data "aws_ssm_parameter" "db_secret_name" {
  name = "${local.ssm_prefix}/database/secret_name"
}

data "aws_ssm_parameter" "db_port" {
  name = "${local.ssm_prefix}/database/port"
}

locals {
  vpc_id             = data.aws_ssm_parameter.vpc_id.value
  vpc_cidr           = data.aws_ssm_parameter.vpc_cidr.value
  private_subnet_ids = split(",", data.aws_ssm_parameter.private_subnet_ids.value)
  db_security_group  = data.aws_ssm_parameter.db_security_group_id.value
  db_secret_arn      = data.aws_ssm_parameter.db_secret_arn.value
  db_secret_name     = data.aws_ssm_parameter.db_secret_name.value
  db_port            = tonumber(data.aws_ssm_parameter.db_port.value)

  artifactory_secret_arn = "arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:${var.artifactory_secret_name}*"
}

# Always boot the newest Amazon Linux 2023 image. AWS keeps the id of the
# current image in a public SSM parameter, so we never hard-code an AMI.
data "aws_ssm_parameter" "al2023_ami" {
  name = var.cpu_architecture == "arm64" ? "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64" : "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}
