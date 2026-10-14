
variable "workspace_name" {
  description = "Unique name of the Databricks workspace."
  type        = string
}

variable "databricks_account_id" {
  description = "Databricks account ID."
  type        = string
  sensitive   = true
}

variable "databricks_workspace_id" {
  description = "ID of the already-created Databricks workspace that will own this catalog's storage credential and external location."
  type        = string
}

variable "aws_account_id" {
  description = "AWS account ID hosting the workspace."
  type        = string
}

variable "aws_region" {
  description = "AWS region hosting the workspace."
  type        = string
}

variable "encryption_customer_managed" {
  description = "Whether application data (the Unity Catalog bucket) requires a dedicated customer-managed KMS key, per the resolved profile's encryption.application_data."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to Unity Catalog data resources."
  type        = map(string)
  default     = {}
}
