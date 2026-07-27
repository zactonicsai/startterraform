# ---------------------------------------------------------------------------
# iam.tf  -  the ID badge each EC2 instance wears.
#
# Instead of putting an access key on the server (bad, keys leak), we attach a
# role. AWS hands the server temporary credentials that rotate automatically.
# The role is allowed to do only three things: read our two secrets, read our
# SSM parameters, and talk to Systems Manager / CloudWatch.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "keycloak" {
  name               = "${local.name_prefix}-keycloak-role"
  assume_role_policy = data.aws_iam_policy_document.assume.json

  tags = { Name = "${local.name_prefix}-keycloak-role" }
}

data "aws_iam_policy_document" "keycloak" {
  # Read ONLY the database secret (and the Artifactory secret if enabled).
  statement {
    sid = "ReadDatabaseSecret"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = compact([
      local.db_secret_arn,
      var.artifactory_auth_enabled ? local.artifactory_secret_arn : "",
    ])
  }

  # Read only OUR parameters, not everyone else's.
  statement {
    sid       = "ReadOwnSsmParameters"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = ["arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter${local.ssm_prefix}/*"]
  }
}

resource "aws_iam_role_policy" "keycloak" {
  name   = "${local.name_prefix}-keycloak-policy"
  role   = aws_iam_role.keycloak.id
  policy = data.aws_iam_policy_document.keycloak.json
}

# Lets you open a shell with Session Manager instead of opening SSH port 22.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.keycloak.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Lets the CloudWatch agent / docker log driver push logs and metrics.
resource "aws_iam_role_policy_attachment" "cloudwatch" {
  count      = var.enable_cloudwatch_logs ? 1 : 0
  role       = aws_iam_role.keycloak.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "keycloak" {
  name = "${local.name_prefix}-keycloak-profile"
  role = aws_iam_role.keycloak.name
}

# Where the container logs go.
resource "aws_cloudwatch_log_group" "keycloak" {
  count             = var.enable_cloudwatch_logs ? 1 : 0
  name              = "/${var.project_name}/${var.environment}/keycloak"
  retention_in_days = var.log_retention_days

  tags = { Name = "${local.name_prefix}-logs" }
}
