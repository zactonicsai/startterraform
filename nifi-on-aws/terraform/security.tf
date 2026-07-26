# Security-group rules reference OTHER SECURITY GROUPS, not IP ranges.
# "Whatever is in the ALB's group may reach me" survives instance replacement
# and re-addressing; a CIDR rule silently rots.

resource "aws_security_group" "alb" {
  count       = local.is_cluster ? 1 : 0
  name        = "${local.name}-alb-sg"
  description = "NiFi load balancer"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.name}-alb-sg" }
}

resource "aws_security_group" "nifi" {
  name        = "${local.name}-nifi-sg"
  description = "NiFi nodes"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.name}-nifi-sg" }
}

resource "aws_security_group" "zk" {
  count       = local.is_cluster ? 1 : 0
  name        = "${local.name}-zk-sg"
  description = "ZooKeeper for NiFi cluster coordination"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.name}-zk-sg" }
}

# ---- egress: everything needs to reach out (Artifactory, CloudWatch, SSM) ----
resource "aws_vpc_security_group_egress_rule" "nifi_out" {
  security_group_id = aws_security_group.nifi.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "pull image, ship logs, reach SSM"
}

resource "aws_vpc_security_group_egress_rule" "alb_out" {
  count             = local.is_cluster ? 1 : 0
  security_group_id = aws_security_group.alb[0].id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "zk_out" {
  count             = local.is_cluster ? 1 : 0
  security_group_id = aws_security_group.zk[0].id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# ---- ingress ----
resource "aws_vpc_security_group_ingress_rule" "alb_from_me" {
  count             = local.is_cluster ? 1 : 0
  security_group_id = aws_security_group.alb[0].id
  cidr_ipv4         = var.allowed_cidr
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "HTTPS from the operator only"
}

resource "aws_vpc_security_group_ingress_rule" "nifi_from_alb" {
  count                        = local.is_cluster ? 1 : 0
  security_group_id            = aws_security_group.nifi.id
  referenced_security_group_id = aws_security_group.alb[0].id
  from_port                    = 8443
  to_port                      = 8443
  ip_protocol                  = "tcp"
  description                  = "UI/API from the load balancer"
}

# Node-to-node. Without 11443 nodes sit at "Connecting" forever.
resource "aws_vpc_security_group_ingress_rule" "nifi_cluster_protocol" {
  count                        = local.is_cluster ? 1 : 0
  security_group_id            = aws_security_group.nifi.id
  referenced_security_group_id = aws_security_group.nifi.id
  from_port                    = 11443
  to_port                      = 11443
  ip_protocol                  = "tcp"
  description                  = "cluster protocol between nodes"
}

# Queue rebalancing between nodes uses its own port.
resource "aws_vpc_security_group_ingress_rule" "nifi_load_balance" {
  count                        = local.is_cluster ? 1 : 0
  security_group_id            = aws_security_group.nifi.id
  referenced_security_group_id = aws_security_group.nifi.id
  from_port                    = 6342
  to_port                      = 6342
  ip_protocol                  = "tcp"
  description                  = "load-balanced connections"
}

resource "aws_vpc_security_group_ingress_rule" "zk_client" {
  count                        = local.is_cluster ? 1 : 0
  security_group_id            = aws_security_group.zk[0].id
  referenced_security_group_id = aws_security_group.nifi.id
  from_port                    = 2181
  to_port                      = 2181
  ip_protocol                  = "tcp"
  description                  = "ZooKeeper client from NiFi"
}
