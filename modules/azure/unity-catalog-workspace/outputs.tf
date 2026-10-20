output "catalog_name" {
  value = databricks_catalog.this.name
}

output "catalog_admin_principal" {
  value = var.catalog_admin_principal
}
