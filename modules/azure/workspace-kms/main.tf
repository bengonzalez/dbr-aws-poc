# Azure analog of modules/aws/workspace-kms (CLAUDE.md §8 milestone 42):
# up to three customer-managed keys, each either created here or brought by
# the client (existing_*_key_id), mirroring AWS's split -
#
#   workspace_storage - managed disks + DBFS root (AWS: EBS + root bucket)
#   managed_services  - control-plane data: notebooks, secrets, queries
#   application_data  - the Unity Catalog ADLS account (AWS: the UC bucket's
#                       key, which lives in modules/aws/unity-catalog-data)
#
# Only the grant that must exist BEFORE the workspace is made here (the
# AzureDatabricks first-party app on the managed-services key). The disk-
# encryption-set and workspace-storage-account identities don't exist until
# the workspace does, so their grants live in modules/azure/workspace-
# deployment; the UC storage account's grant lives in
# modules/azure/unity-catalog-data. All grants are "Key Vault Crypto
# Service Encryption User" (get/wrapKey/unwrapKey), scoped to the single
# key rather than the whole vault - which also works unchanged for a
# client's own vault.
#
# Vaults are RBAC-mode only (a brought vault is checked below); access-
# policy vaults aren't supported.

locals {
  keys = {
    workspace_storage = {
      needed   = var.workspace_cmk_enabled
      existing = var.existing_workspace_storage_key_id
    }
    managed_services = {
      needed   = var.workspace_cmk_enabled
      existing = var.existing_managed_services_key_id
    }
    application_data = {
      needed   = var.application_data_cmk_enabled
      existing = var.existing_application_data_key_id
    }
  }

  create_keys   = toset([for name, key in local.keys : name if key.needed && key.existing == null])
  existing_keys = { for name, key in local.keys : name => key.existing if key.needed && key.existing != null }

  create_vault = length(local.create_keys) > 0

  # Key Vault names: 3-24 chars, alphanumeric/hyphen, globally unique, and
  # reserved for the whole soft-delete retention window after a destroy
  # (purge protection forbids purging early). Hyphens are dropped rather
  # than kept so truncation can never produce a trailing/double hyphen; the
  # random suffix lets the same workspace name be redeployed inside that
  # window without colliding with its own soft-deleted vault.
  vault_name = "kv${substr(replace(lower(var.workspace_name), "-", ""), 0, 15)}${try(random_string.vault_suffix[0].result, "")}"

  # Brought key ids are full ARM resource ids
  # (.../providers/Microsoft.KeyVault/vaults/<vault>/keys/<key>) - the
  # vault id is everything before "/keys/".
  existing_key_vault_ids = { for name, id in local.existing_keys : name => split("/keys/", id)[0] }

  resolved = merge(
    {
      for name in local.create_keys : name => {
        key_id         = azurerm_key_vault_key.this[name].id
        versionless_id = azurerm_key_vault_key.this[name].versionless_id
        resource_id    = azurerm_key_vault_key.this[name].resource_versionless_id
        key_vault_id   = azurerm_key_vault.this[0].id
      }
    },
    {
      for name, id in local.existing_keys : name => {
        key_id         = data.azurerm_key_vault_key.existing[name].id
        versionless_id = data.azurerm_key_vault_key.existing[name].versionless_id
        resource_id    = data.azurerm_key_vault_key.existing[name].resource_versionless_id
        key_vault_id   = local.existing_key_vault_ids[name]
      }
    },
  )
}

data "azurerm_client_config" "current" {}

# The AzureDatabricks first-party enterprise app (same app id in every
# tenant; its object id differs per tenant, so it's looked up, not
# hardcoded).
data "azuread_service_principal" "azure_databricks" {
  count = var.workspace_cmk_enabled ? 1 : 0

  client_id = "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d"
}

resource "random_string" "vault_suffix" {
  count = local.create_vault ? 1 : 0

  length  = 6
  upper   = false
  special = false
}

resource "azurerm_key_vault" "this" {
  count = local.create_vault ? 1 : 0

  name                       = local.vault_name
  resource_group_name        = var.resource_group_name
  location                   = var.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true

  # Required by managed-disk and storage-account CMK. One-way: a destroyed
  # vault stays soft-deleted (name reserved) for the retention window and
  # can't be purged early - 7 days, the minimum.
  purge_protection_enabled   = true
  soft_delete_retention_days = 7

  tags = var.tags
}

# The deploying identity needs data-plane rights to create keys in an
# RBAC-mode vault - being the vault's creator doesn't grant them.
resource "azurerm_role_assignment" "deployer" {
  count = local.create_vault ? 1 : 0

  scope                = azurerm_key_vault.this[0].id
  role_definition_name = "Key Vault Crypto Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# RBAC propagation lag - same class of fix as modules/azure/
# unity-catalog-data's time_sleep.
resource "time_sleep" "deployer_rbac_propagation" {
  count = local.create_vault ? 1 : 0

  create_duration = "60s"

  depends_on = [azurerm_role_assignment.deployer]
}

resource "azurerm_key_vault_key" "this" {
  for_each = local.create_keys

  name         = replace(each.key, "_", "-")
  key_vault_id = azurerm_key_vault.this[0].id
  key_type     = "RSA"
  key_size     = 2048 # one of the RSA sizes Databricks' auto-rotation supports
  key_opts     = ["decrypt", "encrypt", "sign", "unwrapKey", "verify", "wrapKey"]

  tags = var.tags

  depends_on = [time_sleep.deployer_rbac_propagation]
}

# Brought keys: read at plan time, with the vault checked for the two
# properties this module relies on (RBAC mode for the key-scoped grants,
# purge protection because managed-disk/storage CMK require it).
data "azurerm_key_vault" "existing" {
  for_each = local.existing_keys

  name                = element(split("/", local.existing_key_vault_ids[each.key]), 8)
  resource_group_name = element(split("/", local.existing_key_vault_ids[each.key]), 4)

  lifecycle {
    postcondition {
      condition     = self.rbac_authorization_enabled && self.purge_protection_enabled
      error_message = "Key Vault ${self.name} (brought for the ${each.key} key) must have RBAC authorization and purge protection enabled."
    }
  }
}

data "azurerm_key_vault_key" "existing" {
  for_each = local.existing_keys

  name         = element(split("/", each.value), 10)
  key_vault_id = data.azurerm_key_vault.existing[each.key].id
}

resource "azurerm_role_assignment" "azure_databricks_managed_services" {
  count = var.workspace_cmk_enabled ? 1 : 0

  scope                = local.resolved["managed_services"].resource_id
  role_definition_name = "Key Vault Crypto Service Encryption User"
  principal_id         = data.azuread_service_principal.azure_databricks[0].object_id
}

# The workspace validates managed-services key access at create time.
resource "time_sleep" "managed_services_rbac_propagation" {
  count = var.workspace_cmk_enabled ? 1 : 0

  create_duration = "60s"

  depends_on = [azurerm_role_assignment.azure_databricks_managed_services]
}
