# ---------------------------------------------------------------------------
# network.tf  -  the "land" everything else is built on.
#
# Picture a VPC as a fenced piece of land that only you own.
# Inside it we draw two kinds of neighbourhoods (subnets):
#   * public  - has a road to the internet (used later by the load balancer)
#   * private - no road in from the internet (database + Keycloak servers)
# ---------------------------------------------------------------------------

# Ask AWS which Availability Zones (separate data centres) are usable today.
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  # Take only as many AZs as we asked for.
  azs = slice(data.aws_availability_zones.available.names, 0, var.availability_zone_count)

  # How many NAT Gateways to build: 0, 1, or one per AZ.
  nat_gateway_count = var.enable_nat_gateway ? (var.single_nat_gateway ? 1 : var.availability_zone_count) : 0

  # Base path used for every cross-stack value we publish in SSM Parameter Store.
  ssm_prefix = "/${var.project_name}/${var.environment}"
}

# ------------------------------- The VPC -----------------------------------

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true # lets resources resolve names like the RDS endpoint
  enable_dns_hostnames = true # required for RDS private DNS names

  tags = { Name = "${local.name_prefix}-vpc" }
}

# The front door of the VPC. Without it nothing can reach the internet.
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name_prefix}-igw" }
}

# ------------------------------ Subnets ------------------------------------
# cidrsubnet("10.20.0.0/16", 8, 0) => 10.20.0.0/24
# Public subnets get index 0,1,2...  Private subnets start at 10 so the two
# groups never overlap and the numbers stay easy to read.

resource "aws_subnet" "public" {
  count = var.availability_zone_count

  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, var.public_subnet_newbits, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.name_prefix}-public-${local.azs[count.index]}"
    Tier = "public"
  }
}

resource "aws_subnet" "private" {
  count = var.availability_zone_count

  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, var.private_subnet_newbits, count.index + 10)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.name_prefix}-private-${local.azs[count.index]}"
    Tier = "private"
  }
}

# --------------------------- NAT Gateway(s) --------------------------------
# A NAT Gateway is a one-way door: private servers can call OUT to the
# internet (to download the Keycloak Docker image) but nobody can call IN.

resource "aws_eip" "nat" {
  count      = local.nat_gateway_count
  domain     = "vpc"
  depends_on = [aws_internet_gateway.main]

  tags = { Name = "${local.name_prefix}-nat-eip-${count.index}" }
}

resource "aws_nat_gateway" "main" {
  count = local.nat_gateway_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id # NAT always lives in a PUBLIC subnet
  depends_on    = [aws_internet_gateway.main]

  tags = { Name = "${local.name_prefix}-nat-${count.index}" }
}

# ----------------------------- Route tables --------------------------------
# A route table is the "map" a subnet uses to decide where to send traffic.

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name_prefix}-rt-public" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0" # "anything not local"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  count          = var.availability_zone_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# One private route table per AZ so each AZ can use its own NAT when
# single_nat_gateway = false.
resource "aws_route_table" "private" {
  count  = var.availability_zone_count
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name_prefix}-rt-private-${local.azs[count.index]}" }
}

resource "aws_route" "private_nat" {
  count = var.enable_nat_gateway ? var.availability_zone_count : 0

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = var.single_nat_gateway ? aws_nat_gateway.main[0].id : aws_nat_gateway.main[count.index].id
}

resource "aws_route_table_association" "private" {
  count          = var.availability_zone_count
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# --------------------------- Optional flow logs -----------------------------

resource "aws_cloudwatch_log_group" "flow_logs" {
  count             = var.enable_vpc_flow_logs ? 1 : 0
  name              = "/aws/vpc/${local.name_prefix}"
  retention_in_days = var.flow_log_retention_days
}

data "aws_iam_policy_document" "flow_logs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "flow_logs" {
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "flow_logs" {
  count              = var.enable_vpc_flow_logs ? 1 : 0
  name               = "${local.name_prefix}-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume.json
}

resource "aws_iam_role_policy" "flow_logs" {
  count  = var.enable_vpc_flow_logs ? 1 : 0
  name   = "${local.name_prefix}-flow-logs"
  role   = aws_iam_role.flow_logs[0].id
  policy = data.aws_iam_policy_document.flow_logs.json
}

resource "aws_flow_log" "main" {
  count = var.enable_vpc_flow_logs ? 1 : 0

  vpc_id               = aws_vpc.main.id
  traffic_type         = "ALL"
  iam_role_arn         = aws_iam_role.flow_logs[0].arn
  log_destination      = aws_cloudwatch_log_group.flow_logs[0].arn
  log_destination_type = "cloud-watch-logs"

  tags = { Name = "${local.name_prefix}-flow-logs" }
}
