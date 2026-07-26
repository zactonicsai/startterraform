terraform {
  required_version = ">= 1.6.0"

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

  # STRONGLY RECOMMENDED for any real use.
  # Keeps state off your laptop: encrypted, versioned, and locked so two
  # people cannot apply at the same time and corrupt it.
  #
  # Create the bucket first, with versioning enabled, then uncomment:
  #
  # backend "s3" {
  #   bucket       = "mycompany-terraform-state"
  #   key          = "keycloak/prod/terraform.tfstate"
  #   region       = "us-east-1"
  #   encrypt      = true
  #   use_lockfile = true   # native S3 locking, Terraform >= 1.10
  #   # For older versions use: dynamodb_table = "terraform-locks"
  # }
}

provider "aws" {
  region = var.aws_region

  # Applied to every resource this provider creates.
  # Makes cost allocation and the post-destroy orphan hunt trivial.
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
