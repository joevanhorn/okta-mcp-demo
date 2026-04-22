terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # --- CONFIGURE YOUR BACKEND ---
  # Option 1: S3 backend (recommended for teams)
  #   backend "s3" {
  #     bucket         = "YOUR-STATE-BUCKET"
  #     key            = "okta-mcp-demo/terraform.tfstate"
  #     region         = "us-east-2"
  #     dynamodb_table = "YOUR-LOCK-TABLE"   # optional but recommended
  #     encrypt        = true
  #   }
  #
  # Option 2: Local backend (single-user, quick start)
  #   No backend block needed — Terraform defaults to local.
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "okta-mcp-demo"
      ManagedBy = "terraform"
    }
  }
}
