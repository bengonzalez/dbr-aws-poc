terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }

    databricks = {
      source  = "databricks/databricks"
      version = "~> 1.100"
    }

    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }

  # Partial configuration - bucket/key/region/use_lockfile supplied at
  # `terraform init` time via -backend-config (see backend.tfbackend in
  # this directory). Same mechanism as infrastructure/aws/workspace/, but
  # this root has exactly one state key per Databricks account, not per
  # workspace, so there's a single hand-written backend.tfbackend here
  # instead of a generator script - see CLAUDE.md §10 backlog item #1 /
  # §8 milestone 39.
  backend "s3" {}
}
