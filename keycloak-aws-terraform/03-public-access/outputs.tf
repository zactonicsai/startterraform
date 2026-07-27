# ---------------------------------------------------------------------------
# outputs.tf  -  the URL you have been waiting for.
# ---------------------------------------------------------------------------

output "keycloak_url" {
  description = "Open this in a browser. Admin console is this URL + /admin"
  value       = local.https_ready ? "https://${aws_lb.keycloak.dns_name}" : "http://${aws_lb.keycloak.dns_name}"
}

output "keycloak_admin_console_url" {
  description = "Direct link to the admin console."
  value       = local.https_ready ? "https://${aws_lb.keycloak.dns_name}/admin" : "http://${aws_lb.keycloak.dns_name}/admin"
}

output "alb_dns_name" {
  description = "DNS name of the load balancer. Point a CNAME at this."
  value       = aws_lb.keycloak.dns_name
}

output "alb_zone_id" {
  description = "Hosted zone id, needed for a Route53 alias record."
  value       = aws_lb.keycloak.zone_id
}

output "alb_arn" {
  description = "ARN of the load balancer."
  value       = aws_lb.keycloak.arn
}

output "alb_security_group_id" {
  description = "Firewall in front of the load balancer."
  value       = aws_security_group.alb.id
}

output "target_group_arn" {
  description = "Target group the Auto Scaling group registers into."
  value       = aws_lb_target_group.keycloak.arn
}

output "health_check_command" {
  description = "Check which servers the load balancer thinks are healthy."
  value       = "aws elbv2 describe-target-health --target-group-arn ${aws_lb_target_group.keycloak.arn} --region ${var.aws_region}"
}

output "https_enabled" {
  description = "Whether a TLS listener was created."
  value       = local.https_ready
}

output "aws_region" {
  description = "Region this stack was built in (used by the helper scripts)."
  value       = var.aws_region
}
