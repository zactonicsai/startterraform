#!/usr/bin/env bash
# Creates the VPC, 6 subnets across 2 AZs, IGW, NAT gateways and route tables.
. "$(dirname "$0")/lib/common.sh"
load_config; load_state

AZ_A="${AWS_REGION}a"; AZ_B="${AWS_REGION}b"
save AZ_A "$AZ_A"; save AZ_B "$AZ_B"

# ---------- VPC ----------
if already_done VPC_ID; then
  warn "VPC already recorded ($VPC_ID) - skipping creation"
else
  step "Creating VPC 10.0.0.0/16"
  VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 \
    --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${PROJECT}-vpc},{Key=Project,Value=${PROJECT}}]" \
    --query 'Vpc.VpcId' --output text)
  save VPC_ID "$VPC_ID"
  # DNS hostnames are REQUIRED for the RDS endpoint to resolve inside the VPC
  aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support
  aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames
  ok "DNS support and hostnames enabled"
fi

# ---------- subnets ----------
mk_subnet() {  # mk_subnet VARNAME CIDR AZ NAME TIER PUBLIC
  local var="$1" cidr="$2" az="$3" name="$4" tier="$5" pub="$6"
  if already_done "$var"; then warn "$var exists - skipping"; return; fi
  local id
  id=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$cidr" \
    --availability-zone "$az" \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT}-${name}},{Key=Tier,Value=${tier}},{Key=Project,Value=${PROJECT}}]" \
    --query 'Subnet.SubnetId' --output text)
  if [ "$pub" = "yes" ]; then
    aws ec2 modify-subnet-attribute --subnet-id "$id" --map-public-ip-on-launch
  fi
  save "$var" "$id"
}

step "Creating public subnets (ALB + NAT)"
mk_subnet PUB_A 10.0.1.0/24  "$AZ_A" public-a public yes
mk_subnet PUB_B 10.0.2.0/24  "$AZ_B" public-b public yes

step "Creating private app subnets (EC2 + Keycloak)"
mk_subnet APP_A 10.0.11.0/24 "$AZ_A" app-a app no
mk_subnet APP_B 10.0.12.0/24 "$AZ_B" app-b app no

step "Creating private data subnets (RDS)"
mk_subnet DB_A  10.0.21.0/24 "$AZ_A" db-a data no
mk_subnet DB_B  10.0.22.0/24 "$AZ_B" db-b data no

# ---------- internet gateway ----------
if already_done IGW_ID; then
  warn "IGW already recorded - skipping"
else
  step "Creating and attaching internet gateway"
  IGW_ID=$(aws ec2 create-internet-gateway \
    --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${PROJECT}-igw},{Key=Project,Value=${PROJECT}}]" \
    --query 'InternetGateway.InternetGatewayId' --output text)
  save IGW_ID "$IGW_ID"
  aws ec2 attach-internet-gateway --vpc-id "$VPC_ID" --internet-gateway-id "$IGW_ID"
fi

# ---------- public route table ----------
if already_done RTB_PUB; then
  warn "Public route table already recorded - skipping"
else
  step "Creating public route table"
  RTB_PUB=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT}-rtb-public},{Key=Project,Value=${PROJECT}}]" \
    --query 'RouteTable.RouteTableId' --output text)
  save RTB_PUB "$RTB_PUB"
  aws ec2 create-route --route-table-id "$RTB_PUB" \
    --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" >/dev/null
  aws ec2 associate-route-table --route-table-id "$RTB_PUB" --subnet-id "$PUB_A" >/dev/null
  aws ec2 associate-route-table --route-table-id "$RTB_PUB" --subnet-id "$PUB_B" >/dev/null
  ok "Default route 0.0.0.0/0 -> IGW, both public subnets associated"
fi

# ---------- NAT gateways ----------
if already_done NAT_A; then
  warn "NAT gateway A already recorded - skipping"
else
  step "Allocating Elastic IP + creating NAT gateway in AZ A"
  EIP_A=$(aws ec2 allocate-address --domain vpc \
    --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${PROJECT}-eip-a},{Key=Project,Value=${PROJECT}}]" \
    --query 'AllocationId' --output text)
  save EIP_A "$EIP_A"
  NAT_A=$(aws ec2 create-nat-gateway --subnet-id "$PUB_A" --allocation-id "$EIP_A" \
    --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=${PROJECT}-nat-a},{Key=Project,Value=${PROJECT}}]" \
    --query 'NatGateway.NatGatewayId' --output text)
  save NAT_A "$NAT_A"
fi

if [ "${SINGLE_NAT:-false}" = "true" ]; then
  info "SINGLE_NAT=true -> both AZs will share NAT gateway A (cheaper, less resilient)"
  save NAT_B "$NAT_A"
elif already_done NAT_B && [ "$NAT_B" != "$NAT_A" ]; then
  warn "NAT gateway B already recorded - skipping"
else
  step "Allocating Elastic IP + creating NAT gateway in AZ B"
  EIP_B=$(aws ec2 allocate-address --domain vpc \
    --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${PROJECT}-eip-b},{Key=Project,Value=${PROJECT}}]" \
    --query 'AllocationId' --output text)
  save EIP_B "$EIP_B"
  NAT_B=$(aws ec2 create-nat-gateway --subnet-id "$PUB_B" --allocation-id "$EIP_B" \
    --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=${PROJECT}-nat-b},{Key=Project,Value=${PROJECT}}]" \
    --query 'NatGateway.NatGatewayId' --output text)
  save NAT_B "$NAT_B"
fi

step "Waiting for NAT gateway(s) to become available (2-5 minutes)"
if [ "$NAT_A" = "$NAT_B" ]; then
  aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_A"
else
  aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_A" "$NAT_B"
fi
ok "NAT gateway(s) ready"

# ---------- private route tables ----------
mk_private_rtb() {  # mk_private_rtb VAR NAME NATID SUBNET1 SUBNET2
  local var="$1" name="$2" nat="$3" s1="$4" s2="$5"
  if already_done "$var"; then warn "$var exists - skipping"; return; fi
  local id
  id=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT}-${name}},{Key=Project,Value=${PROJECT}}]" \
    --query 'RouteTable.RouteTableId' --output text)
  save "$var" "$id"
  aws ec2 create-route --route-table-id "$id" \
    --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$nat" >/dev/null
  aws ec2 associate-route-table --route-table-id "$id" --subnet-id "$s1" >/dev/null
  aws ec2 associate-route-table --route-table-id "$id" --subnet-id "$s2" >/dev/null
}

step "Creating private route tables (one per AZ)"
mk_private_rtb RTB_A rtb-private-a "$NAT_A" "$APP_A" "$DB_A"
mk_private_rtb RTB_B rtb-private-b "$NAT_B" "$APP_B" "$DB_B"

printf '\n%sNetwork ready. Next: ./02-security-groups.sh%s\n\n' "$C_GRN$C_BOLD" "$C_RESET"
