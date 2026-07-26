#!/usr/bin/env bash
# ===========================================================================
# Security groups: the per-instance firewall.
#
# The important technique here is referencing a security group as the SOURCE
# of a rule instead of an IP range. "Whatever is in the ALB's group may reach
# me on 8443" keeps working when instances are replaced and addresses change.
# An IP-based rule silently rots.
# ===========================================================================
source "$(dirname "$0")/lib/common.sh"

mk_sg() {  # mk_sg VAR name description
  local var="$1" name="$2" desc="$3"
  if have "$var"; then skip "$name exists: ${!var}"; return; fi
  local id
  id=$(aws ec2 create-security-group --group-name "$name" --description "$desc" \
        --vpc-id "$VPC_ID" \
        --tag-specifications "$(tagspec security-group "$name")" \
        --query GroupId --output text)
  remember "$var" "$id"
  ok "$name -> $id"
}

info "Creating groups"
mk_sg NIFI_SG "$PROJECT-nifi-sg" "NiFi nodes"
if is_cluster; then
  mk_sg ALB_SG "$PROJECT-alb-sg" "NiFi load balancer"
  mk_sg ZK_SG  "$PROJECT-zk-sg"  "ZooKeeper for NiFi cluster coordination"
fi

# allow SG_ID proto port source-desc [--sg SOURCE_SG | --cidr CIDR]
allow() {
  local sg="$1" proto="$2" port="$3" desc="$4" kind="$5" src="$6"
  local args=(--group-id "$sg" --protocol "$proto")
  if [ "$port" = all ]; then args+=(--port 0-65535); else args+=(--port "$port"); fi
  if [ "$kind" = sg ]; then args+=(--source-group "$src"); else args+=(--cidr "$src"); fi
  if aws ec2 authorize-security-group-ingress "${args[@]}" >/dev/null 2>&1; then
    ok "$desc"
  else
    skip "$desc (rule already present)"
  fi
}

if is_cluster; then
  info "ALB: only you may reach it"
  allow "$ALB_SG" tcp 443 "443 from $MY_IP_CIDR" cidr "$MY_IP_CIDR"

  info "NiFi: web traffic from the ALB only"
  allow "$NIFI_SG" tcp 8443 "8443 from ALB security group" sg "$ALB_SG"

  info "NiFi: node-to-node cluster protocol"
  # Nodes replicate requests and heartbeats to each other on this port.
  # Without it nodes sit at "Connecting" forever with no useful error.
  allow "$NIFI_SG" tcp 11443 "11443 from other NiFi nodes" sg "$NIFI_SG"
  # Load-balanced connections (queue rebalancing) use their own port.
  allow "$NIFI_SG" tcp 6342  "6342 load-balanced connections" sg "$NIFI_SG"

  info "ZooKeeper: only NiFi may talk to it"
  allow "$ZK_SG" tcp 2181 "2181 client from NiFi" sg "$NIFI_SG"
  allow "$ZK_SG" tcp 2888 "2888 ZK peer" sg "$ZK_SG"
  allow "$ZK_SG" tcp 3888 "3888 ZK election" sg "$ZK_SG"
else
  info "Single node: nothing inbound at all"
  # Deliberately no ingress rule. You reach the UI by tunnelling through
  # Session Manager, which needs no open port. This is genuinely the most
  # secure way to run a single node, and it costs nothing.
  ok "no inbound rules - access is via SSM port forwarding (08-verify.sh)"
fi

ok "Security groups complete"
