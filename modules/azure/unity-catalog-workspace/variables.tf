variable "workspace_name" {
  description = "Unique name of the Databricks workspace. Also used as the catalog name, same as the AWS path."
  type        = string
}

variable "external_location_url" {
  description = "URL of the external location (from modules/azure-unity-catalog-data) backing this workspace's catalog storage root."
  type        = string
}

variable "catalog_admin_principal" {
  description = "A Databricks user name, group name, or service principal application ID to grant ALL_PRIVILEGES on this workspace's catalog. Null skips granting entirely, same as the AWS path."
  type        = string
  default     = null
}
