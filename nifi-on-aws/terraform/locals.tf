locals {
  name       = var.project
  is_cluster = var.node_count > 1

  # Two AZs, taken from whatever the region actually offers rather than
  # hard-coded, so this works in any region.
  azs = slice(data.aws_availability_zones.available.names, 0,
              min(2, length(data.aws_availability_zones.available.names)))

  nifi_image = "${var.artifactory_registry}/${var.artifactory_repo}/apache/nifi:${var.nifi_version}"

  # Roughly half of instance memory to the heap; the rest is left for the OS
  # page cache, which NiFi's repositories depend on heavily.
  heap = lookup({
    "t3.medium"  = "2g"
    "t3.large"   = "4g"
    "m6i.large"  = "4g"
    "m6i.xlarge" = "8g"
    "m7i.large"  = "4g"
  }, var.nifi_instance_type, "4g")

  # Every hostname NiFi will accept in a Host header. Miss the load balancer
  # out and NiFi answers "Invalid host header" for every request through it.
  proxy_hosts = join(",", compact([
    "localhost:8443",
    local.is_cluster ? "${aws_lb.nifi[0].dns_name}:443" : "",
    local.is_cluster ? aws_lb.nifi[0].dns_name : "",
    var.nifi_hostname != "" ? "${var.nifi_hostname}:443" : "",
    var.nifi_hostname != "" ? var.nifi_hostname : "",
  ]))

  log_group = "/${var.project}/nifi"

  # Alternate nodes between AZs so one AZ failing cannot take the cluster.
  node_subnets = { for i in range(var.node_count) :
    i => aws_subnet.private[i % length(local.azs)].id }
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

data "aws_caller_identity" "current" {}
