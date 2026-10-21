# Each output is null when that key isn't needed. Per key:
#   key_id         - versioned https id (workspace CMK arguments want a
#                    specific version, per Databricks' docs)
#   versionless_id - https id without version (storage-account CMK, so it
#                    follows rotation)
#   resource_id    - versionless ARM id, the scope for key-level role
#                    assignments
#   key_vault_id   - ARM id of the containing vault

output "workspace_storage_key" {
  value = lookup(local.resolved, "workspace_storage", null)
}

# Waits on the AzureDatabricks grant's propagation sleep, so a workspace
# that consumes this output is created only once Databricks can reach the
# key.
output "managed_services_key" {
  value      = lookup(local.resolved, "managed_services", null)
  depends_on = [time_sleep.managed_services_rbac_propagation]
}

output "application_data_key" {
  value = lookup(local.resolved, "application_data", null)
}

output "key_vault_id" {
  description = "ARM id of the Key Vault this module created, or null if every key was brought."
  value       = try(azurerm_key_vault.this[0].id, null)
}
