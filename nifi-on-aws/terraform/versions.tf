# Pin both. A new provider version can change resource behaviour and turn an
# unrelated apply into a surprise replacement of something live.
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

  # RECOMMENDED for anything shared. State on a laptop means one person, one
  # machine, and no locking. Uncomment and create the bucket first.
  # backend "s3" {
  #   bucket       = "my-tf-state"
  #   key          = "nifi/terraform.tfstate"
  #   region       = "eu-west-1"
  #   encrypt      = true
  #   use_lockfile = true
  # }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
    }
  }
}
