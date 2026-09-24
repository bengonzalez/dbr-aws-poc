terraform {
  required_version = ">= 1.5.0"

  required_providers {
    databricks = {
      source  = "databricks/databricks"
      version = "~> 1.130"
    }
  }
}

provider "databricks" {
  host    = var.databricks_workspace_url
  profile = var.databricks_profile
}