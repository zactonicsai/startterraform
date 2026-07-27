# ---------------------------------------------------------------------------
# outputs.tf  -  what stack 2 publishes for stack 3 and for humans.
# ---------------------------------------------------------------------------

# ---- Published for stack 3 (the load balancer) ----

resource "aws_ssm_parameter" "keycloak_sg_id" {
  name  = "${local.ssm_prefix}/keycloak/security_group_id"
  type  = "String"
  value = aws_security_group.keycloak.id
}

resource "aws_ssm_parameter" "asg_name" {
  name  = "${local.ssm_prefix}/keycloak/asg_name"
  type  = "String"
  value = aws_autoscaling_group.keycloak.name
}

resource "aws_ssm_parameter" "keycloak_http_port" {
  name  = "${local.ssm_prefix}/keycloak/http_port"
  type  = "String"
  value = tostring(var.keycloak_http_port)
}

resource "aws_ssm_parameter" "keycloak_management_port" {
  name  = "${local.ssm_prefix}/keycloak/management_port"
  type  = "String"
  value = tostring(var.keycloak_management_port)
}

# ---- For humans ----

output "autoscaling_group_name" {
  description = "Name of the Auto Scaling group running Keycloak."
  value       = aws_autoscaling_group.keycloak.name
}

output "keycloak_security_group_id" {
  description = "Firewall around the Keycloak servers."
  value       = aws_security_group.keycloak.id
}

output "launch_template_id" {
  description = "Launch template id (the server recipe)."
  value       = aws_launch_template.keycloak.id
}

output "launch_template_latest_version" {
  description = "Latest version number of the launch template."
  value       = aws_launch_template.keycloak.latest_version
}

output "keycloak_image" {
  description = "Docker image being pulled from Artifactory."
  value       = local.keycloak_image
}

output "iam_role_name" {
  description = "IAM role worn by each Keycloak server."
  value       = aws_iam_role.keycloak.name
}

output "cloudwatch_log_group" {
  description = "Where the container logs land."
  value       = var.enable_cloudwatch_logs ? aws_cloudwatch_log_group.keycloak[0].name : "disabled"
}

output "session_manager_hint" {
  description = "How to open a shell on a server without SSH."
  value       = "aws ssm start-session --target <instance-id> --region ${var.aws_region}"
}

output "aws_region" {
  description = "Region this stack was built in (used by the helper scripts)."
  value       = var.aws_region
}
