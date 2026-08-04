#!/usr/bin/env bash

# Stop if a command fails, an unset variable is used,
# or part of a pipeline fails.
set -euo pipefail

# ---------------------------------------------------------
# Configuration
# ---------------------------------------------------------

AWS_REGION="us-east-1"
PROJECT_NAME="simple-app"

VPC_CIDR="10.20.0.0/16"
PUBLIC_SUBNET_CIDR="10.20.1.0/24"
PRIVATE_SUBNET_CIDR="10.20.10.0/24"

# Change this to your trusted office or home public IP.
# /32 means only this one IP address.
ADMIN_CIDR="203.0.113.10/32"

export AWS_DEFAULT_REGION="$AWS_REGION"

echo "Using AWS region: $AWS_REGION"

# Verify that AWS CLI login works.
aws sts get-caller-identity

# ---------------------------------------------------------
# Find an Availability Zone
# ---------------------------------------------------------

AZ=$(aws ec2 describe-availability-zones \
  --filters "Name=state,Values=available" \
  --query 'AvailabilityZones[0].ZoneName' \
  --output text)

echo "Using Availability Zone: $AZ"

# ---------------------------------------------------------
# Create the VPC
# ---------------------------------------------------------

VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "$VPC_CIDR" \
  --tag-specifications \
    "ResourceType=vpc,Tags=[{Key=Name,Value=${PROJECT_NAME}-vpc},{Key=Project,Value=${PROJECT_NAME}}]" \
  --query 'Vpc.VpcId' \
  --output text)

echo "Created VPC: $VPC_ID"

# Wait until the VPC is ready.
aws ec2 wait vpc-available \
  --vpc-ids "$VPC_ID"

# Enable normal internal DNS name support.
aws ec2 modify-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --enable-dns-support '{"Value":true}'

aws ec2 modify-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --enable-dns-hostnames '{"Value":true}'

# ---------------------------------------------------------
# Create the public subnet
# ---------------------------------------------------------

PUBLIC_SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$PUBLIC_SUBNET_CIDR" \
  --availability-zone "$AZ" \
  --tag-specifications \
    "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT_NAME}-public-subnet},{Key=Network,Value=public},{Key=Project,Value=${PROJECT_NAME}}]" \
  --query 'Subnet.SubnetId' \
  --output text)

echo "Created public subnet: $PUBLIC_SUBNET_ID"

# Automatically give public IPv4 addresses to EC2 instances
# launched into this subnet.
aws ec2 modify-subnet-attribute \
  --subnet-id "$PUBLIC_SUBNET_ID" \
  --map-public-ip-on-launch

# ---------------------------------------------------------
# Create the private subnet
# ---------------------------------------------------------

PRIVATE_SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$PRIVATE_SUBNET_CIDR" \
  --availability-zone "$AZ" \
  --tag-specifications \
    "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT_NAME}-private-subnet},{Key=Network,Value=private},{Key=Project,Value=${PROJECT_NAME}}]" \
  --query 'Subnet.SubnetId' \
  --output text)

echo "Created private subnet: $PRIVATE_SUBNET_ID"

# Make sure instances in this subnet do not automatically
# receive public IPv4 addresses.
aws ec2 modify-subnet-attribute \
  --subnet-id "$PRIVATE_SUBNET_ID" \
  --no-map-public-ip-on-launch

# ---------------------------------------------------------
# Create and attach the Internet Gateway
# ---------------------------------------------------------

IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications \
    "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${PROJECT_NAME}-igw},{Key=Project,Value=${PROJECT_NAME}}]" \
  --query 'InternetGateway.InternetGatewayId' \
  --output text)

echo "Created Internet Gateway: $IGW_ID"

aws ec2 attach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID"

# ---------------------------------------------------------
# Create the public route table
# ---------------------------------------------------------

PUBLIC_ROUTE_TABLE_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
    "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT_NAME}-public-rt},{Key=Network,Value=public},{Key=Project,Value=${PROJECT_NAME}}]" \
  --query 'RouteTable.RouteTableId' \
  --output text)

echo "Created public route table: $PUBLIC_ROUTE_TABLE_ID"

# Send all external IPv4 traffic to the Internet Gateway.
aws ec2 create-route \
  --route-table-id "$PUBLIC_ROUTE_TABLE_ID" \
  --destination-cidr-block "0.0.0.0/0" \
  --gateway-id "$IGW_ID"

# Connect the public subnet to the public route table.
aws ec2 associate-route-table \
  --route-table-id "$PUBLIC_ROUTE_TABLE_ID" \
  --subnet-id "$PUBLIC_SUBNET_ID"

# ---------------------------------------------------------
# Create the private route table
# ---------------------------------------------------------

PRIVATE_ROUTE_TABLE_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
    "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT_NAME}-private-rt},{Key=Network,Value=private},{Key=Project,Value=${PROJECT_NAME}}]" \
  --query 'RouteTable.RouteTableId' \
  --output text)

echo "Created private route table: $PRIVATE_ROUTE_TABLE_ID"

# Notice:
# We do not create a 0.0.0.0/0 route here.
# Therefore, this subnet has no direct Internet access.

aws ec2 associate-route-table \
  --route-table-id "$PRIVATE_ROUTE_TABLE_ID" \
  --subnet-id "$PRIVATE_SUBNET_ID"

# ---------------------------------------------------------
# Create public security group
# ---------------------------------------------------------

PUBLIC_SG_ID=$(aws ec2 create-security-group \
  --group-name "${PROJECT_NAME}-public-sg" \
  --description "Public load balancer or web server security group" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
    "ResourceType=security-group,Tags=[{Key=Name,Value=${PROJECT_NAME}-public-sg},{Key=Project,Value=${PROJECT_NAME}}]" \
  --query 'GroupId' \
  --output text)

echo "Created public security group: $PUBLIC_SG_ID"

# Allow HTTP from the Internet.
aws ec2 authorize-security-group-ingress \
  --group-id "$PUBLIC_SG_ID" \
  --ip-permissions \
    "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0,Description='Public HTTP'}]"

# Allow HTTPS from the Internet.
aws ec2 authorize-security-group-ingress \
  --group-id "$PUBLIC_SG_ID" \
  --ip-permissions \
    "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0,Description='Public HTTPS'}]"

# Optional SSH rule.
# Delete this block when using AWS Systems Manager Session Manager.
aws ec2 authorize-security-group-ingress \
  --group-id "$PUBLIC_SG_ID" \
  --ip-permissions \
    "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${ADMIN_CIDR},Description='Trusted administrator SSH'}]"

# ---------------------------------------------------------
# Create private security group
# ---------------------------------------------------------

PRIVATE_SG_ID=$(aws ec2 create-security-group \
  --group-name "${PROJECT_NAME}-private-sg" \
  --description "Private application server security group" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
    "ResourceType=security-group,Tags=[{Key=Name,Value=${PROJECT_NAME}-private-sg},{Key=Project,Value=${PROJECT_NAME}}]" \
  --query 'GroupId' \
  --output text)

echo "Created private security group: $PRIVATE_SG_ID"

# Allow application traffic only from resources that use
# the public security group.
#
# This is safer than allowing the entire VPC CIDR.
aws ec2 authorize-security-group-ingress \
  --group-id "$PRIVATE_SG_ID" \
  --ip-permissions \
    "IpProtocol=tcp,FromPort=8080,ToPort=8080,UserIdGroupPairs=[{GroupId=${PUBLIC_SG_ID},Description='Application traffic from public load balancer'}]"

# Optional PostgreSQL example.
# This permits PostgreSQL traffic from the public SG.
# For a real design, create a separate application SG and
# allow the database only from that application SG.
#
# aws ec2 authorize-security-group-ingress \
#   --group-id "$PRIVATE_SG_ID" \
#   --ip-permissions \
#     "IpProtocol=tcp,FromPort=5432,ToPort=5432,UserIdGroupPairs=[{GroupId=${PUBLIC_SG_ID},Description='PostgreSQL from application tier'}]"

# ---------------------------------------------------------
# Print the results
# ---------------------------------------------------------

echo
echo "=================================================="
echo "VPC creation completed"
echo "=================================================="
echo "Region:                  $AWS_REGION"
echo "Availability Zone:       $AZ"
echo "VPC ID:                  $VPC_ID"
echo "Public Subnet ID:        $PUBLIC_SUBNET_ID"
echo "Private Subnet ID:       $PRIVATE_SUBNET_ID"
echo "Internet Gateway ID:     $IGW_ID"
echo "Public Route Table ID:   $PUBLIC_ROUTE_TABLE_ID"
echo "Private Route Table ID:  $PRIVATE_ROUTE_TABLE_ID"
echo "Public Security Group:   $PUBLIC_SG_ID"
echo "Private Security Group:  $PRIVATE_SG_ID"
echo "=================================================="

# Save IDs so another script can reuse them.
cat > vpc-resource-ids.env <<EOF
AWS_REGION=$AWS_REGION
AZ=$AZ
VPC_ID=$VPC_ID
PUBLIC_SUBNET_ID=$PUBLIC_SUBNET_ID
PRIVATE_SUBNET_ID=$PRIVATE_SUBNET_ID
IGW_ID=$IGW_ID
PUBLIC_ROUTE_TABLE_ID=$PUBLIC_ROUTE_TABLE_ID
PRIVATE_ROUTE_TABLE_ID=$PRIVATE_ROUTE_TABLE_ID
PUBLIC_SG_ID=$PUBLIC_SG_ID
PRIVATE_SG_ID=$PRIVATE_SG_ID
EOF

echo "Resource IDs saved in vpc-resource-ids.env"