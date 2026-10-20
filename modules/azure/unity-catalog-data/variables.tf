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

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
