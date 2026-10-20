terraform {
  required_version = ">= 1.10.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }

    databricks = {
      source  = "databricks/databricks"
      version = "~> 1.100"
    }

    time = {
      source  = "hashicorp/time"
      version = "~> 0.14"
    }
  }

  # Partial configuration - resource_group_name/storage_account_name/
  # container_name/key are supplied at `terraform init` time via
  # -backend-config=<file> (see resolver/generate_backend_config.py),
  # mirroring the AWS root's partial S3 backend exactly.
  backend "azurerm" {}
}
