# ---------------------------------------------------------------------------
# versions.tf
# Tells Terraform which version of itself and which "plugins" (providers)
# this folder needs. Pinning versions keeps the build repeatable.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Local state by default so the template runs out of the box.
  # For real teams, uncomment and use an S3 backend (see docs/03-operations.md).
  #
  # backend "s3" {
  #   bucket         = "my-tfstate-bucket"
  #   key            = "keycloak/01-network-database/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "my-tfstate-locks"
  #   encrypt        = true
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
        Stack       = "01-network-database"
      },
      var.extra_tags
    )
  }
}
