resource "aws_iam_role" "node" {
  name = "${local.name}-node-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Shell access with no SSH key and no open port 22.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Ship logs off the box, so a terminated node does not take the evidence.
resource "aws_iam_role_policy_attachment" "cw" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# Least privilege: three NAMED secrets, not every secret in the account.
resource "aws_iam_role_policy" "secrets" {
  name = "${local.name}-read-own-secrets"
  role = aws_iam_role.node.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [
        aws_secretsmanager_secret.artifactory.arn,
        aws_secretsmanager_secret.sensitive_props_key.arn,
        aws_secretsmanager_secret.nifi_admin.arn,
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "node" {
  name = "${local.name}-node-profile"
  role = aws_iam_role.node.name
}
