# ---------------------------------------------------------------------------
# security.tf  -  the firewall around the Keycloak servers.
#
# Rule of thumb used everywhere in this project:
#   "the stack that needs the door creates the door"
# So stack 2 punches the hole into the database security group that stack 1
# created, and stack 3 will punch the hole into this security group.
# ---------------------------------------------------------------------------

resource "aws_security_group" "keycloak" {
  name        = "${local.name_prefix}-keycloak-sg"
  description = "Keycloak EC2 instances"
  vpc_id      = local.vpc_id

  tags = { Name = "${local.name_prefix}-keycloak-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

# Outbound: needed to reach Artifactory, the AWS APIs and the database.
resource "aws_vpc_security_group_egress_rule" "keycloak_all" {
  security_group_id = aws_security_group.keycloak.id
  description       = "Allow all outbound (Docker pull, AWS APIs, database)"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# Inbound from other Keycloak nodes - used by Infinispan clustering when
# keycloak_cache_stack is turned on. Harmless when it is off.
resource "aws_vpc_security_group_ingress_rule" "keycloak_cluster" {
  security_group_id            = aws_security_group.keycloak.id
  description                  = "Infinispan cluster traffic between Keycloak nodes"
  ip_protocol                  = "tcp"
  from_port                    = 7800
  to_port                      = 7800
  referenced_security_group_id = aws_security_group.keycloak.id
}

# ------------------ Open the database door for Keycloak --------------------
# This rule is attached to the DATABASE security group (owned by stack 1)
# but is created here, because it references the Keycloak security group.
resource "aws_vpc_security_group_ingress_rule" "database_from_keycloak" {
  security_group_id            = local.db_security_group
  description                  = "PostgreSQL from Keycloak instances"
  ip_protocol                  = "tcp"
  from_port                    = local.db_port
  to_port                      = local.db_port
  referenced_security_group_id = aws_security_group.keycloak.id

  tags = { Name = "${local.name_prefix}-db-from-keycloak" }
}
