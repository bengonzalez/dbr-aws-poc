terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.4"
    }
  }

  # One fixture at a time, fixed key - plain `terraform init` is enough.
  backend "s3" {
    bucket       = "beng-tfstatefiles"
    key          = "fixtures/aws/client-vpc/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      ManagedBy = "terraform"
      Component = "client-vpc-fixture"
      Fixture   = var.workspace_name
    }
  }
}
