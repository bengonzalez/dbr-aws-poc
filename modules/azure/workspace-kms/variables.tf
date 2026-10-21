variable "workspace_name" {
  description = "Unique name of the Databricks workspace. Used to derive the Key Vault name."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group for a created Key Vault (the workspace's own)."
  type        = string
}

variable "location" {
  description = "Azure region for a created Key Vault - must match the workspace's region (Databricks managed-disk CMK requirement)."
  type        = string
}

variable "workspace_cmk_enabled" {
  description = "True when encryption.workspace is customer_managed - provisions/uses the workspace_storage and managed_services keys."
  type        = bool
}

variable "application_data_cmk_enabled" {
  description = "True when encryption.application_data is customer_managed - provisions/uses the application_data key."
  type        = bool
}

variable "existing_workspace_storage_key_id" {
  description = "Full ARM resource id of a client-provided Key Vault key (.../providers/Microsoft.KeyVault/vaults/<vault>/keys/<key>) for managed disks + DBFS root. Null creates one."
  type        = string
  default     = null
}

variable "existing_managed_services_key_id" {
  description = "Full ARM resource id of a client-provided Key Vault key for managed services. Null creates one."
  type        = string
  default     = null
}

variable "existing_application_data_key_id" {
  description = "Full ARM resource id of a client-provided Key Vault key for the Unity Catalog storage account. Null creates one."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to the Key Vault and keys."
  type        = map(string)
  default     = {}
}
