output "workspace_id" {
  value = azurerm_databricks_workspace.this.workspace_id
}

output "workspace_url" {
  value = azurerm_databricks_workspace.this.workspace_url
}

output "resource_group_name" {
  value = azurerm_resource_group.this.name
}

# Consumed by the root's Unity Catalog storage account (composed there, not
# here - see main.tf's header). Null unless application_data is
# customer_managed.
output "application_data_key" {
  value = try(module.kms[0].application_data_key, null)
}
