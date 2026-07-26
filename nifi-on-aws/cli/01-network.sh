#!/usr/bin/env bash
# ===========================================================================
# The network. Three tiers, because where a thing lives decides who can reach it.
#
#   public   - the load balancer and the NAT Gateway. Reachable from internet.
#   private  - the NiFi nodes and ZooKeeper. NO inbound internet route.
#              They reach OUT through NAT to pull the image from Artifactory.
#
# Single-node mode still uses a private subnet: you reach the UI through
# Session Manager port forwarding, so nothing is exposed. See 08-verify.sh.
# ===========================================================================
source "$(dirname "$0")/lib/common.sh"

info "VPC"
if have VPC_ID; then skip "VPC already created: $VPC_ID"; else
  VPC_ID=$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" \
    --tag-specifications "$(tagspec vpc "$PROJECT-vpc")" \
    --query 'Vpc.VpcId' --output text)
  remember VPC_ID "$VPC_ID"
  # RDS-style DNS names and EC2 private DNS both need this. Forgetting it
  # produces "host not found" errors that look like a network fault.
  aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames
  aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support
  ok "created $VPC_ID with DNS hostnames enabled"
fi

info "Availability Zones"
mapfile -t AZ < <(aws ec2 describe-availability-zones \
  --filters Name=state,Values=available \
  --query 'AvailabilityZones[].ZoneName' --output text | tr '\t' '\n' | head -3)
ok "using: ${AZ[*]}"
remember AZ_A "${AZ[0]}"
remember AZ_B "${AZ[1]:-${AZ[0]}}"

mk_subnet() {  # mk_subnet VARNAME cidr az name public?
  local var="$1" cidr="$2" az="$3" name="$4" public="${5:-no}"
  if have "$var"; then skip "$name exists: ${!var}"; return; fi
  local id
  id=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$cidr" \
        --availability-zone "$az" \
        --tag-specifications "$(tagspec subnet "$name")" \
        --query 'Subnet.SubnetId' --output text)
  remember "$var" "$id"
  [ "$public" = yes ] && aws ec2 modify-subnet-attribute --subnet-id "$id" --map-public-ip-on-launch >/dev/null
  ok "$name -> $id ($cidr, $az)"
}

info "Subnets"
mk_subnet PUBLIC_SUBNET_A  "10.20.0.0/24"  "$AZ_A" "$PROJECT-public-a"  yes
mk_subnet PUBLIC_SUBNET_B  "10.20.1.0/24"  "$AZ_B" "$PROJECT-public-b"  yes
mk_subnet PRIVATE_SUBNET_A "10.20.10.0/24" "$AZ_A" "$PROJECT-private-a"
mk_subnet PRIVATE_SUBNET_B "10.20.11.0/24" "$AZ_B" "$PROJECT-private-b"

info "Internet Gateway"
if have IGW_ID; then skip "IGW exists: $IGW_ID"; else
  IGW_ID=$(aws ec2 create-internet-gateway \
    --tag-specifications "$(tagspec internet-gateway "$PROJECT-igw")" \
    --query 'InternetGateway.InternetGatewayId' --output text)
  remember IGW_ID "$IGW_ID"
  aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
  ok "created and attached $IGW_ID"
fi

info "Public route table"
if have PUBLIC_RT; then skip "exists: $PUBLIC_RT"; else
  PUBLIC_RT=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
    --tag-specifications "$(tagspec route-table "$PROJECT-public-rt")" \
    --query 'RouteTable.RouteTableId' --output text)
  remember PUBLIC_RT "$PUBLIC_RT"
  aws ec2 create-route --route-table-id "$PUBLIC_RT" \
    --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" >/dev/null
  for s in "$PUBLIC_SUBNET_A" "$PUBLIC_SUBNET_B"; do
    aws ec2 associate-route-table --route-table-id "$PUBLIC_RT" --subnet-id "$s" >/dev/null
  done
  ok "0.0.0.0/0 -> IGW, associated with both public subnets"
fi

# ---------------------------------------------------------------------------
# NAT Gateway. This is the expensive part: roughly $32/month each plus data
# processing. It exists for ONE reason - so private nodes can pull the NiFi
# image from Artifactory and send logs to CloudWatch.
#
# Single node -> one NAT (cheaper, but a single point of failure).
# Cluster     -> one NAT PER AZ, so losing an AZ does not strand the other.
# ---------------------------------------------------------------------------
info "NAT Gateway(s)"
mk_nat() {  # mk_nat EIP_VAR NAT_VAR public_subnet name
  local eipv="$1" natv="$2" sub="$3" name="$4"
  if have "$natv"; then skip "$name exists: ${!natv}"; return; fi
  local eip nat
  eip=$(aws ec2 allocate-address --domain vpc \
        --tag-specifications "$(tagspec elastic-ip "$name-eip")" \
        --query AllocationId --output text)
  remember "$eipv" "$eip"
  nat=$(aws ec2 create-nat-gateway --subnet-id "$sub" --allocation-id "$eip" \
        --tag-specifications "$(tagspec natgateway "$name")" \
        --query 'NatGateway.NatGatewayId' --output text)
  remember "$natv" "$nat"
  ok "$name -> $nat"
}
mk_nat EIP_A NAT_A "$PUBLIC_SUBNET_A" "$PROJECT-nat-a"
if is_cluster; then mk_nat EIP_B NAT_B "$PUBLIC_SUBNET_B" "$PROJECT-nat-b"; fi

info "Waiting for NAT Gateway(s) - takes 2-3 minutes"
for n in "$NAT_A" "${NAT_B:-}"; do
  [ -z "$n" ] && continue
  waitfor "$n" aws ec2 wait nat-gateway-available --nat-gateway-ids "$n" \
    || die "NAT $n did not become available"
done

info "Private route tables"
mk_private_rt() {  # mk_private_rt RT_VAR nat subnet name
  local var="$1" nat="$2" sub="$3" name="$4"
  if have "$var"; then skip "$name exists: ${!var}"; return; fi
  local rt
  rt=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
        --tag-specifications "$(tagspec route-table "$name")" \
        --query 'RouteTable.RouteTableId' --output text)
  remember "$var" "$rt"
  aws ec2 create-route --route-table-id "$rt" \
    --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$nat" >/dev/null
  aws ec2 associate-route-table --route-table-id "$rt" --subnet-id "$sub" >/dev/null
  ok "$name -> $rt (0.0.0.0/0 via $nat)"
}
mk_private_rt PRIVATE_RT_A "$NAT_A" "$PRIVATE_SUBNET_A" "$PROJECT-private-rt-a"
mk_private_rt PRIVATE_RT_B "${NAT_B:-$NAT_A}" "$PRIVATE_SUBNET_B" "$PROJECT-private-rt-b"

ok "Network complete. Everything recorded in $IDS"
