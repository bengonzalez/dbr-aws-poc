output "workspace_id" {
  value = azurerm_databricks_workspace.this.workspace_id
}

output "workspace_url" {
  value = azurerm_databricks_workspace.this.workspace_url
}

output "resource_group_name" {
  value = azurerm_resource_group.this.name
}
