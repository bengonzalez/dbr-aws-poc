terraform {
  # >= 1.10 is required for the S3 backend's native use_lockfile locking
  # (see the backend block below) - bumped from >= 1.6.0 accordingly.
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
  }

  # Partial configuration - bucket/key/region/use_lockfile are supplied at
  # `terraform init` time via -backend-config=<workspace>.s3.tfbackend (see
  # resolver/generate_backend_config.py). This is what lets every workspace
  # share this one root instead of each getting its own directory: the
  # backend-config selects which workspace's state this root points at.
  backend "s3" {}
}
