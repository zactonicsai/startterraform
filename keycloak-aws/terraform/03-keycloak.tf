###############################################################################
# 03-keycloak.tf
# The Keycloak application server itself, running on one EC2 instance using Docker.
#
# Boot sequence handled by user_data below:
#   1. Install Docker and standard tools
#   2. Fetch the DB password from Secrets Manager using the IAM role
#   3. Download the RDS certificate bundle so TLS can be verified properly
#   4. Generate a self-signed PEM certificate for the admin console
#   5. Build an optimized Keycloak Docker image locally 
#   6. Start the Keycloak container under systemd
###############################################################################

variable "keycloak_version" {
  description = "Keycloak release. 26.7.0 is the current supported release (July 2026)."
  type        = string
  default     = "26.7.0"
}

variable "instance_type" {
  description = <<-EOT
    EC2 size. Keycloak is a Java app and wants RAM more than CPU.
    t4g.small  - 2 GB RAM, ARM Graviton. Minimum that runs comfortably.
    t4g.medium - 4 GB RAM. Recommended.
    t4g.large  - 8 GB RAM. Production single node.
  EOT
  type        = string
  default     = "t4g.small"
}

variable "keycloak_admin_user" {
  description = "Bootstrap admin username for the Keycloak console."
  type        = string
  default     = "kcadmin"
}

variable "ssh_key_name" {
  description = "Existing EC2 key pair name for SSH. Leave empty to use SSM Session Manager only (recommended)."
  type        = string
  default     = ""
}

variable "root_volume_size" {
  description = "Root disk size in GB."
  type        = number
  default     = 20
}

###############################################################################
# AMI LOOKUP
# Amazon Linux 2023, ARM64 (Graviton). Looked up dynamically so you always
# get the latest patched image instead of a stale hard-coded AMI ID.
###############################################################################

data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

###############################################################################
# KEYCLOAK ADMIN PASSWORD
# Generated, stored in Secrets Manager under the same "<project>/db-" prefix
# so the existing least-privilege IAM policy already covers it.
###############################################################################

resource "random_password" "keycloak_admin" {
  length           = 24
  special          = true
  override_special = "!#$%&*-_=+"
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
}

resource "aws_secretsmanager_secret" "keycloak_admin" {
  name                    = "${var.project_name}/db-keycloak-admin-${random_id.suffix.hex}"
  description             = "Keycloak bootstrap admin credentials"
  recovery_window_in_days = 0

  tags = {
    Name = "${var.project_name}-keycloak-admin"
  }
}

resource "aws_secretsmanager_secret_version" "keycloak_admin" {
  secret_id = aws_secretsmanager_secret.keycloak_admin.id

  secret_string = jsonencode({
    username = var.keycloak_admin_user
    password = random_password.keycloak_admin.result
  })
}

###############################################################################
# ELASTIC IP
# A permanent public IP. Without it, stopping and starting the instance hands
# you a brand new address and your bookmark breaks.
###############################################################################

resource "aws_eip" "keycloak" {
  domain = "vpc"

  tags = {
    Name = "${var.project_name}-keycloak-eip"
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_eip_association" "keycloak" {
  instance_id   = aws_instance.keycloak.id
  allocation_id = aws_eip.keycloak.id
}

###############################################################################
# BOOTSTRAP SCRIPT
# Runs once, as root, the first time the instance boots.
# Logs land in /var/log/cloud-init-output.log - check there if something fails.
###############################################################################

locals {
  user_data = <<-BOOTSTRAP
#!/bin/bash
set -euxo pipefail
exec > >(tee /var/log/keycloak-bootstrap.log | logger -t keycloak-bootstrap) 2>&1

echo "=== [1/8] Updating OS packages and installing Docker ==="
dnf update -y
dnf install -y docker jq awscli tar gzip openssl

systemctl enable --now docker

echo "=== [2/8] Creating the Keycloak configuration directories ==="
mkdir -p /opt/keycloak/conf

echo "=== [3/8] Reading secrets via the IAM instance role ==="
export AWS_DEFAULT_REGION="${data.aws_region.current.name}"

DB_SECRET=$(aws secretsmanager get-secret-value \
  --secret-id "${aws_secretsmanager_secret.db.name}" \
  --query SecretString --output text)
DB_USER=$(echo "$DB_SECRET" | jq -r .username)
DB_PASS=$(echo "$DB_SECRET" | jq -r .password)

KC_SECRET=$(aws secretsmanager get-secret-value \
  --secret-id "${aws_secretsmanager_secret.keycloak_admin.name}" \
  --query SecretString --output text)
KC_ADMIN_USER=$(echo "$KC_SECRET" | jq -r .username)
KC_ADMIN_PASS=$(echo "$KC_SECRET" | jq -r .password)

echo "=== [4/8] Downloading the RDS certificate bundle ==="
# This lets us use sslmode=verify-full: the client checks that the
# database really is who it claims to be, not just that TLS is on.
curl -fsSL -o /opt/keycloak/conf/rds-ca.pem \
  "https://truststore.pki.rds.amazonaws.com/${data.aws_region.current.name}/${data.aws_region.current.name}-bundle.pem"
chmod 644 /opt/keycloak/conf/rds-ca.pem

echo "=== [5/8] Generating a TLS PEM certificate for the console ==="
# Self-signed. Your browser will warn you; that is expected for a lab.
PUBLIC_IP="${aws_eip.keycloak.public_ip}"
openssl req -x509 -newkey rsa:2048 -nodes -sha256 \
  -keyout /opt/keycloak/conf/server.key.pem \
  -out /opt/keycloak/conf/server.crt.pem \
  -days 3650 \
  -subj "/CN=$PUBLIC_IP" \
  -addext "subjectAltName=IP:$PUBLIC_IP"

echo "=== [6/8] Writing keycloak.conf ==="
cat > /opt/keycloak/conf/keycloak.conf <<KCCONF
# ---- Database ----
db=postgres
db-url=jdbc:postgresql://${aws_db_instance.keycloak.address}:5432/${var.db_name}?sslmode=verify-full&sslrootcert=/opt/keycloak/conf/rds-ca.pem
db-username=$DB_USER
db-password=$DB_PASS
db-pool-initial-size=5
db-pool-min-size=5
db-pool-max-size=20

# ---- HTTP / HTTPS ----
http-enabled=true
http-port=8080
https-port=8443
https-certificate-file=/opt/keycloak/conf/server.crt.pem
https-certificate-key-file=/opt/keycloak/conf/server.key.pem

# ---- Hostname ----
hostname=https://$PUBLIC_IP:8443
hostname-strict=false

# ---- Health and metrics for monitoring ----
health-enabled=true
metrics-enabled=true

# ---- Logging ----
log=console
log-level=INFO
KCCONF

# Ensure the 'keycloak' user inside the container (UID 1000) can read configurations
chown -R 1000:1000 /opt/keycloak/conf
chmod 600 /opt/keycloak/conf/keycloak.conf

echo "=== [7/8] Building Optimized Keycloak Docker Image ==="
# We copy the config into the image so build-time properties (like health, metrics, and db) 
# are correctly baked into the optimized image before it starts.
cat > /opt/keycloak/Dockerfile <<EOF
FROM quay.io/keycloak/keycloak:${var.keycloak_version}
COPY --chown=1000:1000 conf/ /opt/keycloak/conf/
RUN /opt/keycloak/bin/kc.sh build
EOF

cd /opt/keycloak
docker build -t optimized-keycloak .

echo "=== [8/8] Creating and enabling Systemd unit ==="
cat > /etc/systemd/system/keycloak.service <<UNIT
[Unit]
Description=Keycloak Docker Service
After=docker.service
Requires=docker.service

[Service]
TimeoutStartSec=0
Restart=always
RestartSec=15
ExecStartPre=-/usr/bin/docker rm -f keycloak
ExecStart=/usr/bin/docker run --name keycloak \\
  --ulimit nofile=102642:102642 \\
  -p 8080:8080 -p 8443:8443 \\
  -v /opt/keycloak/conf:/opt/keycloak/conf:ro \\
  -e KC_BOOTSTRAP_ADMIN_USERNAME=$KC_ADMIN_USER \\
  -e KC_BOOTSTRAP_ADMIN_PASSWORD=$KC_ADMIN_PASS \\
  -e JAVA_OPTS_APPEND="-Xms512m -Xmx1024m" \\
  optimized-keycloak \\
  start --optimized
ExecStop=/usr/bin/docker stop keycloak

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now keycloak

echo "=== Bootstrap complete. Keycloak starting on https://$PUBLIC_IP:8443 ==="
  BOOTSTRAP
}

###############################################################################
# THE EC2 INSTANCE
###############################################################################

resource "aws_instance" "keycloak" {
  ami           = data.aws_ssm_parameter.al2023_arm64.value
  instance_type = var.instance_type

  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.keycloak.id]
  iam_instance_profile   = aws_iam_instance_profile.keycloak.name

  # Empty string means "no key pair", which is fine because SSM Session
  # Manager gives you a shell without any SSH key at all.
  key_name = var.ssh_key_name != "" ? var.ssh_key_name : null

  user_data                   = local.user_data
  user_data_replace_on_change = true

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size
    encrypted             = true
    delete_on_termination = true
  }

  # IMDSv2 required. This blocks the classic SSRF attack where a tricked web
  # app is used to steal the instance's IAM credentials.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  monitoring = false # detailed (1-minute) CloudWatch costs extra

  tags = {
    Name = "${var.project_name}-keycloak"
  }

  # Do not try to build the app server before the database exists.
  depends_on = [
    aws_db_instance.keycloak,
    aws_secretsmanager_secret_version.db,
    aws_secretsmanager_secret_version.keycloak_admin,
  ]
}

###############################################################################
# OUTPUTS - the things you actually need after 'terraform apply'
###############################################################################

output "keycloak_url" {
  description = "Open this in your browser (accept the self-signed cert warning)"
  value       = "https://${aws_eip.keycloak.public_ip}:8443"
}

output "keycloak_admin_console" {
  description = "Direct link to the admin console"
  value       = "https://${aws_eip.keycloak.public_ip}:8443/admin"
}

output "keycloak_public_ip" {
  description = "Elastic IP of the Keycloak server"
  value       = aws_eip.keycloak.public_ip
}

output "keycloak_instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.keycloak.id
}

output "keycloak_admin_secret_name" {
  description = "Secrets Manager secret holding the Keycloak admin credentials"
  value       = aws_secretsmanager_secret.keycloak_admin.name
}

output "get_admin_password_command" {
  description = "Run this to retrieve your Keycloak admin password"
  value       = "aws secretsmanager get-secret-value --secret-id ${aws_secretsmanager_secret.keycloak_admin.name} --query SecretString --output text | jq ."
}

output "ssm_shell_command" {
  description = "Get a shell on the server without SSH"
  value       = "aws ssm start-session --target ${aws_instance.keycloak.id}"
}

output "allowed_source_ip" {
  description = "The only IP address permitted to reach Keycloak"
  value       = var.my_ip_cidr
}