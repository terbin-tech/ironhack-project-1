terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.9"
    }
  }

  # bucket and region come from backend.hcl, written by infra/bootstrap:
  #   terraform init -backend-config=backend.hcl
  backend "s3" {
    key          = "ironhack-project-1/main.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Owner   = var.owner
      Project = "ironhack-project-1"
    }
  }
}
