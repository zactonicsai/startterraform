#!/usr/bin/env bash
# ===========================================================================
# ZooKeeper: how NiFi cluster nodes agree on who is in charge.
#
# WHAT IT DOES: elects a Cluster Coordinator (which node accepts joins) and a
# Primary Node (which node runs "primary only" processors, e.g. a ListS3 that
# must not run on all three nodes at once and fetch everything three times).
#
# Skipped entirely when NODE_COUNT=1 - a single node needs no election.
#
# PRODUCTION NOTE: one ZooKeeper is a single point of failure. A real cluster
# runs three, in three AZs. This script deploys one because the guide's job is
# to teach the mechanism; Chapter 12 explains how to make it properly HA.
# ===========================================================================
source "$(dirname "$0")/lib/common.sh"

if ! is_cluster; then
  info "NODE_COUNT=1 - skipping ZooKeeper (not needed for a single node)"
  exit 0
fi

info "Amazon Linux 2023 AMI"
AMI=$(aws ssm get-parameters \
  --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameters[0].Value' --output text)
ok "$AMI"
remember AMI_ID "$AMI"

if have ZK_INSTANCE_ID; then
  skip "ZooKeeper already running: $ZK_INSTANCE_ID"
else
  info "Launching ZooKeeper"
  cat > "$STATE_DIR/zk-user-data.sh" << ZEOF
#!/bin/bash
set -x
exec > >(tee -a /var/log/zk-bootstrap.log) 2>&1
dnf install -y docker
systemctl enable --now docker
docker run -d --name zookeeper --restart unless-stopped \\
  -p 2181:2181 -p 2888:2888 -p 3888:3888 \\
  -e ZOO_MY_ID=1 \\
  -e ZOO_SERVERS="server.1=0.0.0.0:2888:3888;2181" \\
  -e ZOO_4LW_COMMANDS_WHITELIST="srvr,mntr,ruok" \\
  $ZK_IMAGE
ZEOF

  ZK_INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI" \
    --instance-type "$ZK_INSTANCE_TYPE" \
    --subnet-id "$PRIVATE_SUBNET_A" \
    --security-group-ids "$ZK_SG" \
    --iam-instance-profile "Name=$IAM_PROFILE" \
    --user-data "file://$STATE_DIR/zk-user-data.sh" \
    --block-device-mappings "DeviceName=/dev/xvda,Ebs={VolumeSize=20,VolumeType=gp3,DeleteOnTermination=true,Encrypted=true}" \
    --metadata-options "HttpTokens=required" \
    --tag-specifications "$(tagspec instance "$PROJECT-zookeeper")" \
    --query 'Instances[0].InstanceId' --output text)
  remember ZK_INSTANCE_ID "$ZK_INSTANCE_ID"
  ok "launched $ZK_INSTANCE_ID"
fi

info "Waiting for it to run"
aws ec2 wait instance-running --instance-ids "$ZK_INSTANCE_ID"
ZK_IP=$(aws ec2 describe-instances --instance-ids "$ZK_INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
remember ZK_HOST "$ZK_IP"
ok "ZooKeeper private IP: $ZK_IP"

warn "ZooKeeper needs ~90s to finish installing Docker and starting."
warn "NiFi nodes retry their connection, so you can continue now."
