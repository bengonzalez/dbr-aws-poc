output "databricks_ui_api_private_ip" {
  value = azurerm_private_endpoint.databricks_ui_api.private_service_connection[0].private_ip_address
}

output "dbfs_storage_account_id" {
  value = one(local.dbfs_storage_account_ids)
}
