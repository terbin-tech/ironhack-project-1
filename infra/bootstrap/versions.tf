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
