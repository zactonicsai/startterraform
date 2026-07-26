resource "aws_lb" "nifi" {
  count              = local.is_cluster ? 1 : 0
  name               = "${local.name}-alb"
  load_balancer_type = "application"
  internal           = false
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.alb[0].id]

  drop_invalid_header_fields = true
  # The NiFi UI holds long-running requests; the 60s default cuts them off.
  idle_timeout = 300

  tags = { Name = "${local.name}-alb" }
}

resource "aws_lb_target_group" "nifi" {
  count       = local.is_cluster ? 1 : 0
  name        = "${local.name}-tg"
  port        = 8443
  protocol    = "HTTPS" # NiFi speaks HTTPS only
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    protocol = "HTTPS"
    # One of the few NiFi endpoints that answers without a login, which is
    # exactly what a health check needs.
    path                = "/nifi-api/access/config"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 3
    # 200-401: if this version demands auth even here, a 401 still proves the
    # web server is alive. Without the range, an auth challenge reads as
    # "unhealthy" and the ALB drains every node.
    matcher = "200-401"
  }

  # MANDATORY for NiFi. The UI is a single-page app making many API calls;
  # bounce them between nodes and you get random logouts and half-drawn canvases.
  stickiness {
    enabled         = true
    type            = "lb_cookie"
    cookie_duration = 86400
  }

  deregistration_delay = 120
}

resource "aws_lb_target_group_attachment" "nifi" {
  count            = local.is_cluster ? var.node_count : 0
  target_group_arn = aws_lb_target_group.nifi[0].arn
  target_id        = aws_instance.nifi[count.index].id
  port             = 8443
}

resource "aws_lb_listener" "https" {
  count             = local.is_cluster ? 1 : 0
  load_balancer_arn = aws_lb.nifi[0].arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nifi[0].arn
  }

  lifecycle {
    precondition {
      condition     = var.acm_certificate_arn != ""
      error_message = "node_count > 1 creates an HTTPS load balancer, which needs acm_certificate_arn (in this same region)."
    }
  }
}

resource "aws_route53_record" "nifi" {
  count   = local.is_cluster && var.hosted_zone_id != "" && var.nifi_hostname != "" ? 1 : 0
  zone_id = var.hosted_zone_id
  name    = var.nifi_hostname
  type    = "A"
  alias {
    name                   = aws_lb.nifi[0].dns_name
    zone_id                = aws_lb.nifi[0].zone_id
    evaluate_target_health = true
  }
}
