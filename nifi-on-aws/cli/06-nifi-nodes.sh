#!/usr/bin/env bash
# ===========================================================================
#  The NiFi nodes themselves.
#
#  READ THIS - IT IS THE MOST IMPORTANT DESIGN DECISION IN THE WHOLE KIT.
#
#  These are discrete EC2 instances, each with its OWN persistent EBS data
#  volume. They are NOT in an Auto Scaling Group. That is deliberate.
#
#  An ASG's job is to terminate an unhealthy instance and launch a fresh
#  replacement. For a stateless app that is perfect. For NiFi it is data loss:
#  the flowfile and content repositories on that instance held real data that
#  was mid-journey, and a fresh instance starts with empty repositories.
#
#  NiFi clustering does NOT rescue that data. "Offloading" a node moves its
#  work elsewhere, but offloading requires the node to be ALIVE. A node that
#  died takes its in-flight data with it until you bring the disk back.
#
#  So: fixed instances, and a data volume with DeleteOnTermination=false that
#  survives and can be re-attached to a replacement. Chapter 7 of the guide
#  covers the trade-offs and when an ASG IS the right answer.
# ===========================================================================
source "$(dirname "$0")/lib/common.sh"

info "Log group for NiFi logs"
LOG_GROUP="/$PROJECT/nifi"
aws logs create-log-group --log-group-name "$LOG_GROUP" 2>/dev/null || skip "log group exists"
# Never leave retention unset: "never expire" is the default and it bills forever.
aws logs put-retention-policy --log-group-name "$LOG_GROUP" --retention-in-days 30
ok "$LOG_GROUP (30-day retention)"
remember LOG_GROUP "$LOG_GROUP"

info "AMI"
if have AMI_ID; then skip "$AMI_ID"; else
  AMI_ID=$(aws ssm get-parameters \
    --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
    --query 'Parameters[0].Value' --output text)
  remember AMI_ID "$AMI_ID"; ok "$AMI_ID"
fi

# Heap: roughly half the instance memory, leaving the rest for the OS page
# cache, which NiFi leans on heavily for repository IO.
case "$NIFI_INSTANCE_TYPE" in
  t3.medium)      HEAP="2g" ;;
  t3.large|m6i.large|m7i.large)  HEAP="4g" ;;
  *xlarge)        HEAP="8g" ;;
  *)              HEAP="4g" ;;
esac
ok "JVM heap per node: $HEAP"

# Which hostnames NiFi will accept in a Host header. If the ALB name is not in
# here, every request through the load balancer is rejected with
# "Invalid host header" and the UI shows a blank page. This is THE most common
# NiFi-behind-a-proxy failure.
PROXY_HOSTS="localhost:8443"
if is_cluster; then
  [ -n "${ALB_DNS:-}" ] && PROXY_HOSTS="$ALB_DNS:443,$ALB_DNS"
  [ -n "${NIFI_HOSTNAME:-}" ] && PROXY_HOSTS="$PROXY_HOSTS,$NIFI_HOSTNAME:443,$NIFI_HOSTNAME"
  if [ -z "${ALB_DNS:-}" ]; then
    warn "ALB not created yet, so its DNS name is not in nifi.web.proxy.host."
    warn "  Run 07-alb.sh, then re-run this script's proxy update step:"
    warn "  ./06-nifi-nodes.sh --refresh-proxy"
  fi
fi
ok "nifi.web.proxy.host will be: $PROXY_HOSTS"

render_user_data() {
  local out="$1"
  sed -e "s|@@REGION@@|$AWS_REGION|g" \
      -e "s|@@PROJECT@@|$PROJECT|g" \
      -e "s|@@NIFI_IMAGE@@|$NIFI_IMAGE|g" \
      -e "s|@@REGISTRY@@|$ARTIFACTORY_REGISTRY|g" \
      -e "s|@@IS_CLUSTER@@|$(is_cluster && echo true || echo false)|g" \
      -e "s|@@ZK_HOST@@|${ZK_HOST:-none}|g" \
      -e "s|@@PROXY_HOSTS@@|$PROXY_HOSTS|g" \
      -e "s|@@HEAP@@|$HEAP|g" \
      -e "s|@@ELECTION_WAIT@@|1 min|g" \
      -e "s|@@LOG_GROUP@@|$LOG_GROUP|g" \
      templates/nifi-user-data.sh.tmpl > "$out"
}

if [ "${1:-}" = "--refresh-proxy" ]; then
  info "Refreshing nifi.web.proxy.host on existing nodes"
  for i in $(seq 1 "$NODE_COUNT"); do
    eval "id=\${NIFI_INSTANCE_$i:-}"
    [ -z "$id" ] && continue
    warn "restarting NiFi on $id with the ALB name included"
    aws ssm send-command --instance-ids "$id" \
      --document-name AWS-RunShellScript \
      --parameters "commands=[\"docker rm -f nifi\",\"bash /var/lib/cloud/instance/user-data.txt\"]" \
      --query 'Command.CommandId' --output text >/dev/null 2>&1 \
      && ok "$id restarting" || warn "$id - send-command failed, restart it by hand"
  done
  exit 0
fi

info "Launching $NODE_COUNT NiFi node(s)"
for i in $(seq 1 "$NODE_COUNT"); do
  VAR="NIFI_INSTANCE_$i"
  if have "$VAR"; then skip "node $i exists: ${!VAR}"; continue; fi

  # Spread nodes across AZs so one AZ failure cannot take the cluster.
  if [ $((i % 2)) -eq 1 ]; then SUBNET="$PRIVATE_SUBNET_A"; else SUBNET="$PRIVATE_SUBNET_B"; fi

  render_user_data "$STATE_DIR/user-data-$i.sh"

  ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$NIFI_INSTANCE_TYPE" \
    --subnet-id "$SUBNET" \
    --security-group-ids "$NIFI_SG" \
    --iam-instance-profile "Name=$IAM_PROFILE" \
    --user-data "file://$STATE_DIR/user-data-$i.sh" \
    --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=2" \
    --block-device-mappings \
      "DeviceName=/dev/xvda,Ebs={VolumeSize=$ROOT_VOLUME_GB,VolumeType=gp3,DeleteOnTermination=true,Encrypted=true}" \
      "DeviceName=/dev/sdf,Ebs={VolumeSize=$DATA_VOLUME_GB,VolumeType=$DATA_VOLUME_TYPE,DeleteOnTermination=false,Encrypted=true}" \
    --tag-specifications \
      "$(tagspec instance "$PROJECT-nifi-$i")" \
      "$(tagspec volume "$PROJECT-nifi-$i-vol")" \
    --query 'Instances[0].InstanceId' --output text)
  remember "$VAR" "$ID"
  ok "node $i -> $ID in $SUBNET"
done

info "Waiting for instances to run"
IDS=()
for i in $(seq 1 "$NODE_COUNT"); do eval "IDS+=(\$NIFI_INSTANCE_$i)"; done
aws ec2 wait instance-running --instance-ids "${IDS[@]}"
ok "all running"

info "Node addresses"
for i in $(seq 1 "$NODE_COUNT"); do
  eval "id=\$NIFI_INSTANCE_$i"
  read -r ip dns < <(aws ec2 describe-instances --instance-ids "$id" \
    --query 'Reservations[0].Instances[0].[PrivateIpAddress,PrivateDnsName]' --output text)
  remember "NIFI_IP_$i" "$ip"
  ok "node $i: $ip ($dns)"
done

cat <<'TXT'

    Bootstrap takes 3-6 minutes: install Docker, mount the volume, pull the
    image from Artifactory, start NiFi, wait for the API.

    Watch a node do it:
      aws ssm start-session --target <instance-id>
      sudo tail -f /var/log/nifi-bootstrap.log
TXT
