aws_region = "us-east-1"
identifier = "keycloak-db"

# Existing subnets (must span at least 2 AZs for RDS)
subnet_ids = [
  "subnet-0fb7bd0981c9fe2eb",
  "subnet-07fbf78e0480dd08b",
]

# Existing security group(s) that already allow inbound 5432 from the app tier
vpc_security_group_ids = [
  "sg-05faba222f961a7e3",
]

db_name     = "appdb"
db_username = "dbadmin"
# Do NOT set db_password here. Provide it via:
#   export TF_VAR_db_password='your-secure-password'
# or a CI/CD secret, or AWS Secrets Manager + a data source.

instance_class    = "db.t3.micro"
allocated_storage = 20
multi_az          = false

tags = {
  Environment = "production"
  Project     = "myapp"
}
