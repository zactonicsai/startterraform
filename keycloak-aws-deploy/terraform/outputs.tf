output "keycloak_url" {
  description = "Where users log in"
  value       = "https://${var.domain_name}"
}

output "keycloak_admin_url" {
  description = "Admin console"
  value       = "https://${var.domain_name}/admin"
}

output "alb_dns_name" {
  description = "Direct ALB address, useful before DNS propagates"
  value       = aws_lb.main.dns_name
}

output "db_endpoint" {
  description = "RDS endpoint"
  value       = aws_db_instance.main.endpoint
  sensitive   = true
}

output "db_secret_name" {
  description = "Read the DB password with: aws secretsmanager get-secret-value --secret-id <this>"
  value       = aws_secretsmanager_secret.db.name
}

output "bootstrap_admin_secret_name" {
  description = "First-login credentials. DELETE THE USER AND THIS SECRET after setup."
  value       = aws_secretsmanager_secret.kc_admin.name
}

output "asg_name" {
  description = "Auto Scaling Group name, for instance refreshes"
  value       = aws_autoscaling_group.keycloak.name
}

output "target_group_arn" {
  description = "For checking target health"
  value       = aws_lb_target_group.keycloak.arn
}

output "log_group" {
  description = "Where Keycloak container logs go"
  value       = aws_cloudwatch_log_group.keycloak.name
}

output "next_steps" {
  description = "What to do once apply finishes"
  value       = <<-EOT

    1. Wait 4-6 minutes for the first instance to become healthy:
         aws elbv2 describe-target-health --target-group-arn ${aws_lb_target_group.keycloak.arn}

    2. Verify the OIDC issuer is correct (this catches a wrong KC_HOSTNAME):
         curl -s https://${var.domain_name}/realms/master/.well-known/openid-configuration | jq -r .issuer
       Expected: https://${var.domain_name}/realms/master

    3. Get the bootstrap password:
         aws secretsmanager get-secret-value --secret-id ${aws_secretsmanager_secret.kc_admin.name} --query SecretString --output text

    4. Log in at https://${var.domain_name}/admin then IMMEDIATELY:
         - create a real named admin account and enable OTP/MFA
         - delete the 'tmpadmin' bootstrap user
         - create a separate realm for your applications (never use 'master')

    5. Attach an SNS topic to the alarms in alarms.tf, or they fire silently.

  EOT
}
