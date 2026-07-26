resource "aws_cloudwatch_log_group" "nifi" {
  name = local.log_group
  # Never leave this unset: the default is "never expire" and it bills forever.
  retention_in_days = var.log_retention_days
}

# ---------------------------------------------------------------------------
# ZooKeeper. Only in cluster mode - a single node needs no election.
# One instance here for teaching; production wants three across AZs.
# ---------------------------------------------------------------------------
resource "aws_instance" "zookeeper" {
  count                  = local.is_cluster ? 1 : 0
  ami                    = nonsensitive(data.aws_ssm_parameter.al2023.value)
  instance_type          = var.zk_instance_type
  subnet_id              = aws_subnet.private[0].id
  vpc_security_group_ids = [aws_security_group.zk[0].id]
  iam_instance_profile   = aws_iam_instance_profile.node.name

  metadata_options {
    http_tokens = "required" # IMDSv2 only
  }

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = <<-EOT
    #!/bin/bash
    set -x
    exec > >(tee -a /var/log/zk-bootstrap.log) 2>&1
    dnf install -y docker
    systemctl enable --now docker
    docker run -d --name zookeeper --restart unless-stopped \
      -p 2181:2181 -p 2888:2888 -p 3888:3888 \
      -e ZOO_MY_ID=1 \
      -e ZOO_SERVERS="server.1=0.0.0.0:2888:3888;2181" \
      -e ZOO_4LW_COMMANDS_WHITELIST="srvr,mntr,ruok" \
      zookeeper:3.9
  EOT

  tags = { Name = "${local.name}-zookeeper", Role = "zookeeper" }
}

# ---------------------------------------------------------------------------
# THE DATA VOLUMES - a separate resource, deliberately.
#
# Declaring them as their own aws_ebs_volume rather than an inline
# ebs_block_device means Terraform can replace an INSTANCE without destroying
# the DISK. That is the whole point: NiFi holds in-flight data locally, and a
# fresh empty volume is data loss.
#
# `terraform destroy` DOES delete these. Snapshot first: make snapshot
# ---------------------------------------------------------------------------
resource "aws_ebs_volume" "data" {
  count             = var.node_count
  availability_zone = local.azs[count.index % length(local.azs)]
  size              = var.data_volume_gb
  type              = "gp3"
  encrypted         = true
  tags              = { Name = "${local.name}-nifi-${count.index}-data", Role = "nifi-data" }
}

resource "aws_instance" "nifi" {
  count                  = var.node_count
  ami                    = nonsensitive(data.aws_ssm_parameter.al2023.value)
  instance_type          = var.nifi_instance_type
  subnet_id              = aws_subnet.private[count.index % length(local.azs)].id
  vpc_security_group_ids = [aws_security_group.nifi.id]
  iam_instance_profile   = aws_iam_instance_profile.node.name

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2 # so a container can still read metadata
  }

  root_block_device {
    volume_size = var.root_volume_gb
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = templatefile("${path.module}/user-data.sh.tftpl", {
    region        = var.aws_region
    project       = var.project
    nifi_image    = local.nifi_image
    registry      = var.artifactory_registry
    is_cluster    = local.is_cluster
    zk_host       = local.is_cluster ? aws_instance.zookeeper[0].private_ip : "none"
    proxy_hosts   = local.proxy_hosts
    heap          = local.heap
    log_group     = local.log_group
    election_wait = "1 min"
  })

  # Changing user_data replaces the instance. That is acceptable here ONLY
  # because the data lives on a separate volume that survives.
  user_data_replace_on_change = true

  tags = { Name = "${local.name}-nifi-${count.index}", Role = "nifi" }

  depends_on = [aws_nat_gateway.main, aws_iam_role_policy.secrets]
}

resource "aws_volume_attachment" "data" {
  count       = var.node_count
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data[count.index].id
  instance_id = aws_instance.nifi[count.index].id

  # Do not try to detach on destroy. A forced detach of a mounted filesystem
  # can corrupt it, and the instance is going away anyway.
  skip_destroy = true
}
