data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name = "${var.project_name}-${var.environment}"

  azs = slice(data.aws_availability_zones.available.names, 0, var.availability_zone_count)

  # cidrsubnet does the subnet maths so you don't make an off-by-one error.
  # cidrsubnet("10.0.0.0/16", 8, 11) -> "10.0.11.0/24"
  #   public -> 10.0.1.0/24,  10.0.2.0/24
  #   app    -> 10.0.11.0/24, 10.0.12.0/24
  #   data   -> 10.0.21.0/24, 10.0.22.0/24
  subnets = merge(
    { for i, az in local.azs : "public-${i}" => {
      az   = az
      cidr = cidrsubnet(var.vpc_cidr, 8, i + 1)
      tier = "public"
    } },
    { for i, az in local.azs : "app-${i}" => {
      az   = az
      cidr = cidrsubnet(var.vpc_cidr, 8, i + 11)
      tier = "app"
    } },
    { for i, az in local.azs : "data-${i}" => {
      az   = az
      cidr = cidrsubnet(var.vpc_cidr, 8, i + 21)
      tier = "data"
    } },
  )

  public_subnet_keys = [for k, v in local.subnets : k if v.tier == "public"]
  app_subnet_keys    = [for k, v in local.subnets : k if v.tier == "app"]
  data_subnet_keys   = [for k, v in local.subnets : k if v.tier == "data"]

  nat_gateway_count = var.single_nat_gateway ? 1 : var.availability_zone_count
}
