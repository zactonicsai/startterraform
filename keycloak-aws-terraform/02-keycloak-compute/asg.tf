# ---------------------------------------------------------------------------
# asg.tf  -  the launch template (the recipe for one server) and the
#            Auto Scaling group (the thing that keeps N copies running).
# ---------------------------------------------------------------------------

locals {
  # Turn the extra_env map into plain KEY=VALUE lines for the env file.
  extra_env_lines = join("\n", [for k, v in var.keycloak_extra_env : "${k}=${v}"])

  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", {
    aws_region               = var.aws_region
    db_secret_name           = local.db_secret_name
    keycloak_image           = local.keycloak_image
    artifactory_registry     = var.artifactory_registry
    artifactory_auth_enabled = var.artifactory_auth_enabled
    artifactory_secret_name  = var.artifactory_secret_name
    admin_username           = var.keycloak_admin_username
    admin_password           = var.keycloak_admin_password
    keycloak_http_port       = var.keycloak_http_port
    keycloak_management_port = var.keycloak_management_port
    keycloak_hostname        = var.keycloak_hostname
    keycloak_cache_stack     = var.keycloak_cache_stack
    java_opts                = var.keycloak_java_opts
    extra_env_lines          = local.extra_env_lines
    enable_cloudwatch_logs   = var.enable_cloudwatch_logs
    log_group                = var.enable_cloudwatch_logs ? aws_cloudwatch_log_group.keycloak[0].name : ""
  })
}

resource "aws_launch_template" "keycloak" {
  name_prefix   = "${local.name_prefix}-keycloak-"
  image_id      = data.aws_ssm_parameter.al2023_ami.value
  instance_type = var.instance_type

  # No SSH key on purpose. Use AWS Session Manager to get a shell:
  #   aws ssm start-session --target i-0123456789abcdef0
  iam_instance_profile {
    arn = aws_iam_instance_profile.keycloak.arn
  }

  vpc_security_group_ids = [aws_security_group.keycloak.id]

  user_data = base64encode(local.user_data)

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.root_volume_size
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  # Force IMDSv2. This blocks a whole family of credential-stealing attacks.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2 # 2 so a container can still reach metadata
    instance_metadata_tags      = "enabled"
  }

  monitoring {
    enabled = var.enable_detailed_monitoring
  }

  dynamic "instance_market_options" {
    for_each = var.use_spot_instances ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        spot_instance_type = "one-time"
      }
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${local.name_prefix}-keycloak"
      Role = "keycloak"
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name = "${local.name_prefix}-keycloak-volume"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "keycloak" {
  name = "${local.name_prefix}-keycloak-asg"

  # The Keycloak servers sit in the SAME private subnets as the database,
  # exactly as the requirement asks.
  vpc_zone_identifier = local.private_subnet_ids

  min_size         = var.asg_min_size
  max_size         = var.asg_max_size
  desired_capacity = var.asg_desired_capacity

  health_check_type         = var.asg_health_check_type
  health_check_grace_period = var.asg_health_check_grace_period
  default_cooldown          = 60
  wait_for_capacity_timeout = "10m"

  launch_template {
    id      = aws_launch_template.keycloak.id
    version = aws_launch_template.keycloak.latest_version
  }

  # Roll out new versions one at a time, keeping most of the fleet online.
  dynamic "instance_refresh" {
    for_each = var.enable_instance_refresh ? [1] : []
    content {
      strategy = "Rolling"
      preferences {
        min_healthy_percentage = 50
        instance_warmup        = tostring(var.asg_health_check_grace_period)
      }
    }
  }

  tag {
    key                 = "Name"
    value               = "${local.name_prefix}-keycloak"
    propagate_at_launch = true
  }

  tag {
    key                 = "Project"
    value               = var.project_name
    propagate_at_launch = true
  }

  tag {
    key                 = "Environment"
    value               = var.environment
    propagate_at_launch = true
  }

  lifecycle {
    # NOTE: deliberately NOT create_before_destroy. This ASG has a fixed name,
    # and a "create first" replacement would collide with the existing name.
    # Stack 3 attaches this ASG to the load balancer target group.
    # Ignoring the field stops the two stacks from fighting each other.
    ignore_changes = [target_group_arns, load_balancers]
  }
}

# Optional: grow and shrink the fleet based on average CPU.
resource "aws_autoscaling_policy" "cpu" {
  count = var.enable_cpu_autoscaling ? 1 : 0

  name                   = "${local.name_prefix}-cpu-target"
  autoscaling_group_name = aws_autoscaling_group.keycloak.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = var.cpu_target_percent
  }
}
