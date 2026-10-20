# Azure's Unity Catalog storage-credential chain - direct same-shape port
# of modules/unity-catalog-data's AWS chain, with Azure-native primitives,
# validated against a real Azure subscription (throwaway spike, see the
# Azure milestone's CLAUDE.md entry).
#
# Real, validated difference from AWS: this module receives a
# WORKSPACE-URL-scoped `databricks` provider from the caller (passed down
# as the plain default provider, not an aliased one - see
# infrastructure/workspace-azure/main.tf), not an account-console
# provider + provider_config{workspace_id}. That's why there is no
# databricks_workspace_binding here at all (confirmed unnecessary by the
# spike - AWS needs those only because its storage credential/external
# location are created through the account-level provider, which doesn't
# auto-bind isolated resources to the creating workspace), and no
# metastore_id argument on the storage credential (also confirmed
# unnecessary for a workspace-scoped provider, unlike AWS's account-level
# provider which requires it).

resource "azurerm_storage_account" "unity_catalog_data" {
  name                     = var.storage_account_name
  resource_group_name      = var.resource_group_name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"
  is_hns_enabled           = true # required for ADLS Gen2

  tags = var.tags
}

resource "azurerm_storage_data_lake_gen2_filesystem" "unity_catalog_data" {
  name               = "uc-root"
  storage_account_id = azurerm_storage_account.unity_catalog_data.id
}

resource "azurerm_databricks_access_connector" "unity_catalog_data" {
  name                = "dbac-${var.workspace_name}-uc"
  resource_group_name = var.resource_group_name
  location            = var.location

  identity {
    type = "SystemAssigned"
  }

  tags = var.tags
}

resource "azurerm_role_assignment" "unity_catalog_data" {
  scope                = azurerm_storage_account.unity_catalog_data.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_databricks_access_connector.unity_catalog_data.identity[0].principal_id
}

# RBAC propagation lag - same class of fix as AWS's
# time_sleep.unity_catalog_iam_propagation (CLAUDE.md Sec8 milestone 19),
# applied here for the Azure equivalent (role assignment vs. IAM policy
# attachment).
resource "time_sleep" "unity_catalog_rbac_propagation" {
  create_duration = "60s"

  depends_on = [
    azurerm_role_assignment.unity_catalog_data
  ]
}

resource "databricks_storage_credential" "this" {
  name = "${var.workspace_name}-uc-storage-credential"

  azure_managed_identity {
    access_connector_id = azurerm_databricks_access_connector.unity_catalog_data.id
  }

  depends_on = [
    time_sleep.unity_catalog_rbac_propagation
  ]
}

resource "databricks_external_location" "this" {
  name            = "${var.workspace_name}-uc-external-location"
  url             = "abfss://${azurerm_storage_data_lake_gen2_filesystem.unity_catalog_data.name}@${azurerm_storage_account.unity_catalog_data.name}.dfs.core.windows.net/"
  credential_name = databricks_storage_credential.this.name
  comment         = "Managed by Terraform for workspace ${var.workspace_name}."
}
