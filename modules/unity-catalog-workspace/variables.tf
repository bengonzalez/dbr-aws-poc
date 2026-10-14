
variable "workspace_name" {
  description = "Unique name of the Databricks workspace. Also used as the catalog name - workspace names and catalog names share one uniqueness domain in this factory."
  type        = string
}

variable "databricks_account_id" {
  description = "Databricks account ID."
  type        = string
  sensitive   = true
}

variable "databricks_workspace_id" {
  description = "ID of the already-created Databricks workspace to assign the metastore to and bind the catalog to."
  type        = string
}

variable "existing_metastore_id" {
  description = "ID of the existing, platform-owned Unity Catalog metastore this workspace should be assigned to. Not created by this factory - see CLAUDE.md Sec6."
  type        = string
}

variable "uc_bucket_name" {
  description = "Name of the S3 bucket (from modules/unity-catalog-data) backing this workspace's catalog storage root."
  type        = string
}

variable "catalog_admin_principal" {
  description = "A Databricks user name, group name, or service principal application ID to grant ALL_PRIVILEGES on this workspace's catalog. Null skips granting entirely - the catalog owner then defaults to whoever runs terraform apply, same as today. No identity/access model exists elsewhere in this pipeline (CLAUDE.md Sec6), so this is deliberately optional and deployment-only, not resolved automatically."
  type        = string
  default     = null
}
