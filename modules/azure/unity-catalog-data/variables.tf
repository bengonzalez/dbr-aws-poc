variable "workspace_name" {
  description = "Unique name of the Databricks workspace."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group to create the ADLS Gen2 storage account/access connector in."
  type        = string
}

variable "location" {
  description = "Azure region for the storage account/access connector."
  type        = string
}

variable "storage_account_name" {
  description = "Globally-unique ADLS Gen2 storage account name (Azure storage account names are limited to 24 lowercase alphanumeric characters, so this is computed by the caller rather than derived here from a human-readable workspace name that might not fit/be unique)."
  type        = string
}

variable "application_data_cmk_enabled" {
  description = "Whether application_data_key is in use. A separate, plan-time-known flag: application_data_key's own nullness isn't known at plan when the key is created in the same run, so it can't drive count."
  type        = bool
  default     = false
}

variable "application_data_key" {
  description = "Customer-managed key for the UC storage account, from modules/azure/workspace-kms's application_data_key output. Null (default) leaves the account on Microsoft-managed keys."
  type = object({
    key_id         = string
    versionless_id = string
    resource_id    = string
    key_vault_id   = string
  })
  default = null
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
