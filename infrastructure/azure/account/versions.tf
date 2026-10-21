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
  }

  # Partial configuration - resource_group_name/storage_account_name/
  # container_name/key supplied at `terraform init` time via
  # -backend-config (see backend.tfbackend in this directory), mirroring
  # infrastructure/azure/workspace/'s partial azurerm backend. This root
  # has exactly one state key per Databricks account, not per workspace,
  # so backend.tfbackend here is a single hand-written file instead of a
  # generator script - see CLAUDE.md §10 backlog item #1a / §8
  # milestone 40.
  backend "azurerm" {}
}
