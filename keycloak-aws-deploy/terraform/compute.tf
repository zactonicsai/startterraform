data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# Centralised logs are CRITICAL here: when the ASG destroys a failing
# instance, its local logs die with it. This is the only way to find out
# what happened.
resource "aws_cloudwatch_log_group" "keycloak" {
  name              = "/${local.name}/keycloak"
  retention_in_days = var.log_retention_days
}

resource "aws_launch_template" "keycloak" {
  name_prefix   = "${local.name}-"
  image_id      = data.aws_ssm_parameter.al2023_ami.value
  instance_type = var.instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.app.name
  }

  vpc_security_group_ids = [aws_security_group.app.id]

  user_data = base64encode(templatefile("${path.module}/user-data.sh.tftpl", {
    aws_region             = var.aws_region
    db_secret_arn          = aws_secretsmanager_secret.db.arn
    artifactory_secret_arn = aws_secretsmanager_secret.artifactory.arn
    kc_admin_secret_arn    = aws_secretsmanager_secret.kc_admin.arn
    artifactory_host       = var.artifactory_host
    keycloak_image         = var.keycloak_image
    db_endpoint            = aws_db_instance.main.endpoint
    domain_name            = var.domain_name
    log_group_name         = aws_cloudwatch_log_group.keycloak.name
    db_pool_max_size       = var.db_pool_max_size
  }))

  # ---------------------------------------------------------------------
  # IMDSv2 required. The metadata service at 169.254.169.254 is where an
  # instance gets its IAM credentials. IMDSv1 could be tricked by a
  # Server-Side Request Forgery attack - the exact vulnerability behind
  # the 2019 Capital One breach. IMDSv2 needs a token from a PUT request,
  # which SSRF generally cannot perform.
  #
  # hop_limit = 2 allows the extra hop a Docker container needs.
  # ---------------------------------------------------------------------
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "enabled"
  }

  # 1-minute metrics instead of 5. Costs a little; worth it for
  # autoscaling responsiveness.
  monitoring {
    enabled = true
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = var.root_volume_size
      volume_type = "gp3"
      encrypted   = true
      # Without this you accumulate orphaned volumes that quietly cost
      # money forever every time the ASG replaces an instance.
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${local.name}-node" }
  }

  tag_specifications {
    resource_type = "volume"
    tags          = { Name = "${local.name}-volume" }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "keycloak" {
  name_prefix = "${local.name}-"

  min_size         = var.asg_min_size
  max_size         = var.asg_max_size
  desired_capacity = var.asg_min_size

  # Listing BOTH app subnets is what gives you AZ redundancy. Listing only
  # one means you have thrown it away while believing you are highly
  # available.
  vpc_zone_identifier = [for k in local.app_subnet_keys : aws_subnet.this[k].id]

  # Auto-registers each new instance with the load balancer and
  # deregisters it on termination. No manual step.
  target_group_arns = [aws_lb_target_group.keycloak.arn]

  # THE self-healing switch. The default, "EC2", only notices if the
  # virtual machine has failed - a hung Keycloak on a healthy VM would be
  # left in place forever. "ELB" means the ASG trusts the load balancer's
  # HTTP health check and replaces instances whose APPLICATION is broken.
  health_check_type = "ELB"

  # Give a new instance 5 minutes to boot, pull the image and start the JVM
  # before health checks count against it. Too short and you get an
  # infinite kill-and-relaunch loop.
  health_check_grace_period = 300
  default_instance_warmup   = 300

  termination_policies = ["OldestInstance"]

  launch_template {
    id      = aws_launch_template.keycloak.id
    version = aws_launch_template.keycloak.latest_version
  }

  # ---------------------------------------------------------------------
  # Zero-downtime deploys. Change keycloak_image, run apply, and the ASG
  # rolls through the fleet: launch new, wait for healthy, terminate old.
  # min_healthy_percentage = 100 means it always adds before it removes,
  # so capacity never dips. The checkpoints pause halfway for 2 minutes,
  # giving you a window to spot a problem and abort.
  # ---------------------------------------------------------------------
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 100
      instance_warmup        = 300
      checkpoint_percentages = [50, 100]
      checkpoint_delay       = 120
    }
    triggers = ["launch_template"]
  }

  dynamic "tag" {
    for_each = {
      Name        = "${local.name}-node"
      Project     = var.project_name
      Environment = var.environment
    }
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    create_before_destroy = true
    # The scaling policy changes this constantly. Without ignoring it,
    # every apply would yank the fleet back to the minimum.
    ignore_changes = [desired_capacity]
  }

  # Instances must not launch before the database exists, or they
  # crash-loop.
  depends_on = [aws_db_instance.main]
}

# Target tracking works like a thermostat: you state the goal and AWS
# creates the alarms and holds the number.
#
# Why 60% and not 90%? Scaling takes ~3 minutes (boot + pull + JVM +
# health checks). If you wait for 90% you will be at 100% and dropping
# requests before help arrives. The 40% headroom is your buffer.
resource "aws_autoscaling_policy" "cpu" {
  name                   = "${local.name}-cpu-target"
  autoscaling_group_name = aws_autoscaling_group.keycloak.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 60.0
  }
}
