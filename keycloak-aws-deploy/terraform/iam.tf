data "aws_iam_policy_document" "ec2_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app" {
  name_prefix        = "${local.name}-app-"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# Session Manager: shell access with no open port 22, no key files,
# and every session logged in CloudTrail.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cloudwatch" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# ---------------------------------------------------------------------------
# Least privilege: the Resource list names the three exact secret ARNs.
#
# A lazier version would say "Resource": "*", which would let a compromised
# Keycloak instance read EVERY secret in the account - other teams' database
# passwords, API keys, everything. Never do that.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "read_secrets" {
  statement {
    sid     = "ReadOnlyTheseThreeSecrets"
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      aws_secretsmanager_secret.db.arn,
      aws_secretsmanager_secret.artifactory.arn,
      aws_secretsmanager_secret.kc_admin.arn,
    ]
  }
}

resource "aws_iam_role_policy" "read_secrets" {
  name_prefix = "${local.name}-secrets-"
  role        = aws_iam_role.app.id
  policy      = data.aws_iam_policy_document.read_secrets.json
}

# An instance profile is the wrapper that lets EC2 actually use a role.
# Historical AWS plumbing: you need both.
resource "aws_iam_instance_profile" "app" {
  name_prefix = "${local.name}-app-"
  role        = aws_iam_role.app.name
}
