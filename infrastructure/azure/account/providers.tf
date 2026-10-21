provider "azurerm" {
  features {}
}

provider "databricks" {
  alias = "mws"

  host       = "https://accounts.azuredatabricks.net"
  account_id = var.databricks_account_id
  auth_type  = "azure-cli"
}
