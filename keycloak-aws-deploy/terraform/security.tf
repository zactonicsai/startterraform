# ---------------------------------------------------------------------------
# Security group chaining is the key idea here.
#
# We reference other SECURITY GROUPS, not CIDR blocks, for internal traffic.
# "Allow 5432 from the app security group" instead of "from 10.0.11.0/24".
#
# Why it matters: launching a random EC2 instance in the app subnet does NOT
# grant it database access unless it also wears the app security group badge.
# And if you ever change your IP layout, nothing breaks.
#
# name_prefix + create_before_destroy lets Terraform replace a group without
# a deadlock (with a fixed name it would have to delete the old one first,
# but it cannot, because things are still attached).
# ---------------------------------------------------------------------------

resource "aws_security_group" "alb" {
  name_prefix = "${local.name}-alb-"
  description = "Public HTTPS entry point"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-alb-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from the internet"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "alb_http_redirect" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP, only to be redirected to HTTPS"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_all" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---------------------------- app tier -------------------------------------

resource "aws_security_group" "app" {
  name_prefix = "${local.name}-app-"
  description = "Keycloak EC2 instances"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-app-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "app_http_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "Application traffic from ALB only"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "app_health_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "Health checks on the management port"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 9000
  to_port                      = 9000
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "app_cluster" {
  security_group_id            = aws_security_group.app.id
  description                  = "Infinispan/JGroups cluster traffic between nodes"
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = 7800
  to_port                      = 7801
  ip_protocol                  = "tcp"
}

# Needed to reach Artifactory, RDS and the AWS APIs.
# Note there is NO port 22 rule anywhere: shell access is via SSM.
resource "aws_vpc_security_group_egress_rule" "app_all" {
  security_group_id = aws_security_group.app.id
  description       = "Reach Artifactory, RDS, and AWS APIs"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# --------------------------- database tier ---------------------------------

resource "aws_security_group" "rds" {
  name_prefix = "${local.name}-rds-"
  description = "PostgreSQL, app tier only"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-rds-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_app" {
  security_group_id            = aws_security_group.rds.id
  description                  = "PostgreSQL from Keycloak nodes only"
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}
