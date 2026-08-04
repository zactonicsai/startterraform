# RDS PostgreSQL (existing subnets & security groups)

Creates **only** an RDS PostgreSQL instance and its DB subnet group. It assumes your
VPC, subnets, and security groups already exist — it does not create or modify them.

## Files
- `main.tf` – provider, `aws_db_subnet_group`, `aws_db_instance`
- `variables.tf` – all inputs
- `outputs.tf` – endpoint, address, port, ARN, etc.
- `terraform.tfvars.example` – sample values

## Usage

1. Copy the example vars file and fill in your real IDs:
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```
2. Edit `terraform.tfvars` with your existing `subnet_ids` and `vpc_security_group_ids`.
3. Set the master password out-of-band (never commit it):
   ```bash
   export TF_VAR_db_password='a-strong-password'
   ```
4. Run:
   ```bash
   terraform init
   terraform plan
   terraform apply
   ```

## Using tags instead of hardcoded IDs (optional)

If you'd rather look up existing subnets/security groups by tag instead of pasting IDs,
replace the `subnet_ids` / `vpc_security_group_ids` variables with data sources in `main.tf`:

```hcl
data "aws_subnets" "existing" {
  filter {
    name   = "tag:Tier"
    values = ["private"]
  }
}

data "aws_security_group" "existing" {
  filter {
    name   = "tag:Name"
    values = ["rds-postgres-sg"]
  }
}

# then reference:
# subnet_ids             = data.aws_subnets.existing.ids
# vpc_security_group_ids = [data.aws_security_group.existing.id]
```

## Notes
- `storage_encrypted = true` and `deletion_protection = true` are on by default — override
  in `terraform.tfvars` if that doesn't fit your environment.
- Instance is **not publicly accessible** by default; the existing security group(s) you
  attach must already allow inbound TCP 5432 from whatever needs to reach it.
- No VPC, subnets, or security groups are created, modified, or destroyed by this config.
