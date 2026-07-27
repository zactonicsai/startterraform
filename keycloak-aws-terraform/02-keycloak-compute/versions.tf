# ---------------------------------------------------------------------------
# versions.tf  -  same idea as stack 1: pin Terraform and the AWS provider.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }

  # backend "s3" {
  #   bucket = "my-tfstate-bucket"
  #   key    = "keycloak/02-keycloak-compute/terraform.tfstate"
  #   region = "us-east-1"
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = merge(
      {
        Project     = var.project_name
        Environment = var.environment
        ManagedBy   = "terraform"
        Stack       = "02-keycloak-compute"
      },
      var.extra_tags
    )
  }
}
