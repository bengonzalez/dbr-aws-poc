terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
    }

    databricks = {
      source = "databricks/databricks"
    }

    time = {
      source = "hashicorp/time"
    }
  }
}
