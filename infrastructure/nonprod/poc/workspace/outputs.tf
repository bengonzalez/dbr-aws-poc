output "databricks_storage_credential_name" {
  value = databricks_storage_credential.data_access.name
}

output "databricks_external_location_name" {
  value = databricks_external_location.data.name
}

output "databricks_catalog_name" {
  value = databricks_catalog.poc.name
}

output "databricks_schema_name" {
  value = databricks_schema.poc.name
}

output "databricks_validation_table_name" {
  value = databricks_sql_table.validation.name
}