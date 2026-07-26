resource "aws_lb" "main" {
  name_prefix        = substr(var.project_name, 0, 6)
  load_balancer_type = "application"
  internal           = false

  subnets         = [for k in local.public_subnet_keys : aws_subnet.this[k].id]
  security_groups = [aws_security_group.alb.id]

  enable_deletion_protection = var.enable_deletion_protection
  drop_invalid_header_fields = true
  idle_timeout               = 120

  tags = { Name = "${local.name}-alb" }
}

resource "aws_lb_target_group" "keycloak" {
  name_prefix = "kc-"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  # On removal, stop sending NEW requests but wait 60s for in-flight ones.
  # This is what makes deploys graceful instead of dropping users mid-login.
  deregistration_delay = 60

  health_check {
    enabled  = true
    protocol = "HTTP"

    # Keycloak 25+ serves health on a SEPARATE management port (9000),
    # not the main HTTP port. Real traffic goes to 8080, checks to 9000.
    port = "9000"

    # /health/ready means "ready to serve traffic, including a working
    # database connection". Do not use /health/live here - you do not want
    # traffic sent to an instance that is alive but cannot reach the DB.
    path = "/health/ready"

    interval            = 15
    timeout             = 5
    healthy_threshold   = 2 # must pass twice: prevents flapping
    unhealthy_threshold = 3 # 3 x 15s = 45s tolerance before eviction
    matcher             = "200"
  }

  # A performance optimisation, NOT a correctness requirement. Keycloak
  # replicates sessions between nodes, so it works without stickiness -
  # but keeping a user on the node that owns their session is faster.
  stickiness {
    enabled         = true
    type            = "lb_cookie"
    cookie_duration = 3600
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"

  # TLS 1.2 and 1.3 only. Never use a policy whose name includes
  # TLS-1-0 or TLS-1-1.
  ssl_policy      = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.keycloak.arn
  }
}

# Users type "auth.example.com" with no scheme and browsers try HTTP first.
# Redirect rather than closing port 80, so they get a working experience.
resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      protocol    = "HTTPS"
      port        = "443"
      status_code = "HTTP_301"
    }
  }
}
