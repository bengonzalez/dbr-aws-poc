variable "workspace_name" {
  description = "Unique name of the Databricks workspace."
  type        = string
}

variable "databricks_account_id" {
  description = "Databricks account ID used to scope control-plane KMS access."
  type        = string
  sensitive   = true
}

variable "aws_account_id" {
  description = "AWS account ID hosting the workspace, granted full key administration."
  type        = string
}

variable "cross_account_role_arn" {
  description = "ARN of the Databricks cross-account IAM role, granted EBS encryption access on the workspace storage key."
  type        = string
}

variable "tags" {
  description = "Tags applied to the KMS keys."
  type        = map(string)
  default     = {}
}

variable "existing_workspace_storage_key_arn" {
  description = "ARN of an existing KMS key to use for workspace storage instead of creating one."
  type        = string
  default     = null
}

variable "existing_workspace_storage_key_alias" {
  description = "Alias name of the existing workspace storage key, if any."
  type        = string
  default     = null
}

variable "existing_managed_services_key_arn" {
  description = "ARN of an existing KMS key to use for managed services instead of creating one."
  type        = string
  default     = null
}

variable "existing_managed_services_key_alias" {
  description = "Alias name of the existing managed services key, if any."
  type        = string
  default     = null
}
