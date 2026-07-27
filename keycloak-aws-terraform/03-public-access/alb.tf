# ---------------------------------------------------------------------------
# alb.tf  -  the public front door.
#
# An Application Load Balancer (ALB) sits in the PUBLIC subnets, listens on
# port 80 (and 443 if you turn HTTPS on), and forwards every request to the
# Keycloak servers hiding in the PRIVATE subnets.
#
# Why an ALB and not something else?
#   * It is the cheapest managed option that understands HTTP, does health
#     checks, sticky sessions and TLS termination for free.
#   * ~USD 16/month base + a tiny per-request charge.
#   * A Network Load Balancer costs about the same but cannot do cookies or
#     path rules. Running your own NGINX on EC2 is cheaper but then YOU patch
#     it, monitor it and make it highly available.
# ---------------------------------------------------------------------------

locals {
  name_prefix = "${var.project_name}-${var.environment}"
  ssm_prefix  = "/${var.project_name}/${var.environment}"
}

# ------------------- Read what stacks 1 and 2 published --------------------

data "aws_ssm_parameter" "vpc_id" {
  name = "${local.ssm_prefix}/network/vpc_id"
}

data "aws_ssm_parameter" "public_subnet_ids" {
  name = "${local.ssm_prefix}/network/public_subnet_ids"
}

data "aws_ssm_parameter" "keycloak_sg_id" {
  name = "${local.ssm_prefix}/keycloak/security_group_id"
}

data "aws_ssm_parameter" "asg_name" {
  name = "${local.ssm_prefix}/keycloak/asg_name"
}

data "aws_ssm_parameter" "keycloak_http_port" {
  name = "${local.ssm_prefix}/keycloak/http_port"
}

data "aws_ssm_parameter" "keycloak_management_port" {
  name = "${local.ssm_prefix}/keycloak/management_port"
}

locals {
  vpc_id            = data.aws_ssm_parameter.vpc_id.value
  public_subnet_ids = split(",", data.aws_ssm_parameter.public_subnet_ids.value)
  keycloak_sg_id    = data.aws_ssm_parameter.keycloak_sg_id.value
  asg_name          = data.aws_ssm_parameter.asg_name.value
  keycloak_port     = tonumber(data.aws_ssm_parameter.keycloak_http_port.value)
  management_port   = tonumber(data.aws_ssm_parameter.keycloak_management_port.value)

  https_ready = var.enable_https && var.acm_certificate_arn != ""
}

# --------------------------- Load balancer firewall -------------------------

resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb-sg"
  description = "Public entry point for Keycloak"
  vpc_id      = local.vpc_id

  tags = { Name = "${local.name_prefix}-alb-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  count = length(var.allowed_cidr_blocks)

  security_group_id = aws_security_group.alb.id
  description       = "HTTP from allowed clients"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = var.allowed_cidr_blocks[count.index]
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  count = local.https_ready ? length(var.allowed_cidr_blocks) : 0

  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from allowed clients"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = var.allowed_cidr_blocks[count.index]
}

resource "aws_vpc_security_group_egress_rule" "alb_to_keycloak" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Forward traffic to Keycloak"
  ip_protocol                  = "tcp"
  from_port                    = local.keycloak_port
  to_port                      = local.keycloak_port
  referenced_security_group_id = local.keycloak_sg_id
}

resource "aws_vpc_security_group_egress_rule" "alb_healthcheck" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Health checks to the Keycloak management port"
  ip_protocol                  = "tcp"
  from_port                    = local.management_port
  to_port                      = local.management_port
  referenced_security_group_id = local.keycloak_sg_id
}

# These two rules are attached to the KEYCLOAK security group (owned by stack
# 2) but created here. Destroying stack 3 therefore closes the door again -
# the servers become unreachable from outside, which is exactly what you want.
resource "aws_vpc_security_group_ingress_rule" "keycloak_from_alb" {
  security_group_id            = local.keycloak_sg_id
  description                  = "Application traffic from the load balancer"
  ip_protocol                  = "tcp"
  from_port                    = local.keycloak_port
  to_port                      = local.keycloak_port
  referenced_security_group_id = aws_security_group.alb.id

  tags = { Name = "${local.name_prefix}-keycloak-from-alb" }
}

resource "aws_vpc_security_group_ingress_rule" "keycloak_health_from_alb" {
  security_group_id            = local.keycloak_sg_id
  description                  = "Health checks from the load balancer"
  ip_protocol                  = "tcp"
  from_port                    = local.management_port
  to_port                      = local.management_port
  referenced_security_group_id = aws_security_group.alb.id

  tags = { Name = "${local.name_prefix}-keycloak-health-from-alb" }
}

# ------------------------------ Load balancer -------------------------------

resource "aws_lb" "keycloak" {
  name               = trimsuffix(substr("${local.name_prefix}-alb", 0, 32), "-")
  load_balancer_type = "application"
  internal           = var.internal
  subnets            = local.public_subnet_ids
  security_groups    = [aws_security_group.alb.id]

  idle_timeout               = var.idle_timeout
  enable_http2               = var.enable_http2
  drop_invalid_header_fields = var.drop_invalid_header_fields
  enable_deletion_protection = var.enable_deletion_protection

  dynamic "access_logs" {
    for_each = var.enable_access_logs && var.access_logs_bucket != "" ? [1] : []
    content {
      bucket  = var.access_logs_bucket
      prefix  = local.name_prefix
      enabled = true
    }
  }

  tags = { Name = "${local.name_prefix}-alb" }
}

# ------------------------------ Target group --------------------------------
# A target group is the list of servers the load balancer may send traffic to.
# The Auto Scaling group adds and removes members automatically.

resource "aws_lb_target_group" "keycloak" {
  name        = trimsuffix(substr("${local.name_prefix}-tg", 0, 32), "-")
  port        = local.keycloak_port
  protocol    = "HTTP"
  vpc_id      = local.vpc_id
  target_type = "instance"

  deregistration_delay = var.deregistration_delay

  health_check {
    enabled             = true
    path                = var.health_check_path
    port                = tostring(local.management_port) # Keycloak 25+ serves health on 9000
    protocol            = "HTTP"
    matcher             = "200"
    interval            = var.health_check_interval
    timeout             = var.health_check_timeout
    healthy_threshold   = var.healthy_threshold
    unhealthy_threshold = var.unhealthy_threshold
  }

  dynamic "stickiness" {
    for_each = var.enable_stickiness ? [1] : []
    content {
      type            = "lb_cookie"
      cookie_duration = var.stickiness_duration
      enabled         = true
    }
  }

  tags = { Name = "${local.name_prefix}-tg" }

  lifecycle {
    create_before_destroy = true
  }
}

# Plug stack 2's Auto Scaling group into this target group.
resource "aws_autoscaling_attachment" "keycloak" {
  count = var.attach_asg ? 1 : 0

  autoscaling_group_name = local.asg_name
  lb_target_group_arn    = aws_lb_target_group.keycloak.arn
}

# -------------------------------- Listeners ---------------------------------
# A listener is "when traffic arrives on port X, do Y".

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.keycloak.arn
  port              = 80
  protocol          = "HTTP"

  # If HTTPS is on and redirect is wanted, bounce visitors to 443.
  dynamic "default_action" {
    for_each = local.https_ready && var.redirect_http_to_https ? [1] : []
    content {
      type = "redirect"
      redirect {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }

  # Otherwise serve Keycloak directly over plain HTTP.
  dynamic "default_action" {
    for_each = local.https_ready && var.redirect_http_to_https ? [] : [1]
    content {
      type             = "forward"
      target_group_arn = aws_lb_target_group.keycloak.arn
    }
  }
}

resource "aws_lb_listener" "https" {
  count = local.https_ready ? 1 : 0

  load_balancer_arn = aws_lb.keycloak.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = var.ssl_policy
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.keycloak.arn
  }
}
