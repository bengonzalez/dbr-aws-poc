
output "catalog_name" {
  description = "Name of the Unity Catalog catalog created for this workspace."
  value       = databricks_catalog.this.name
}

output "metastore_id" {
  description = "ID of the metastore this workspace was assigned to."
  value       = var.existing_metastore_id
}

output "catalog_admin_principal" {
  description = "Principal granted ALL_PRIVILEGES on the catalog, when set; null otherwise."
  value       = var.catalog_admin_principal
}
