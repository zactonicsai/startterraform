output "mode" {
  value = local.is_cluster ? "cluster (${var.node_count} nodes, ALB, ZooKeeper)" : "single node (no ALB)"
}

output "nifi_url" {
  description = "Where to open NiFi"
  value = local.is_cluster ? (
    var.nifi_hostname != "" ? "https://${var.nifi_hostname}/nifi" : "https://${aws_lb.nifi[0].dns_name}/nifi"
  ) : "no public endpoint - use the ssm_port_forward command below"
}

output "ssm_port_forward" {
  description = "Reach a private node with no open ports at all"
  value = <<-TXT
    aws ssm start-session --target ${aws_instance.nifi[0].id} \
      --document-name AWS-StartPortForwardingSession \
      --parameters '{"portNumber":["8443"],"localPortNumber":["8443"]}'
    then open https://localhost:8443/nifi
  TXT
}

output "get_admin_password" {
  value = "aws secretsmanager get-secret-value --secret-id ${var.project}/nifi-admin --query SecretString --output text | jq -r .password"
}

output "get_sensitive_props_key" {
  description = "SAVE THIS OUTSIDE AWS. Flow secrets are unrecoverable without it."
  value       = "aws secretsmanager get-secret-value --secret-id ${var.project}/sensitive-props-key --query SecretString --output text"
}

output "node_ids" {
  value = aws_instance.nifi[*].id
}

output "data_volume_ids" {
  description = "Snapshot these before destroying - they hold in-flight data"
  value       = aws_ebs_volume.data[*].id
}

output "log_group" {
  value = aws_cloudwatch_log_group.nifi.name
}

output "next_steps" {
  value = <<-TXT

    1. Nodes take 3-6 minutes to bootstrap (docker, mount volume, pull image).
    2. Cluster mode: check target health before opening the UI -
         aws elbv2 describe-target-health --target-group-arn ${try(aws_lb_target_group.nifi[0].arn, "n/a")}
    3. Save the sensitive props key somewhere permanent (command above).
    4. Before any destroy:  make snapshot
  TXT
}
