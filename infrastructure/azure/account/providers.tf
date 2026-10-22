provider "azurerm" {
  features {}
}

provider "databricks" {
  alias = "mws"

  host       = "https://accounts.azuredatabricks.net"
  account_id = var.databricks_account_id
  auth_type  = "azure-cli"

  # Pinned rather than auto-discovered: for a guest identity (a user whose
  # home tenant differs from this subscription's), the SDK's discovery
  # requests a token from the HOME tenant, which the account rejects with
  # "Expected iss claim to be: https://sts.windows.net/<this tenant>/"
  # (found standing up the real account, CLAUDE.md §8 milestone 44).
  azure_tenant_id = data.azurerm_client_config.current.tenant_id
}

data "azurerm_client_config" "current" {}
