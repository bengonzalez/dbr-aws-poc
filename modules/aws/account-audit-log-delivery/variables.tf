variable "databricks_account_id" {
  description = "ID of the Databricks account audit logs are delivered for."
  type        = string
}

variable "resource_prefix" {
  description = "Prefix for the log-delivery bucket/role/credential names."
  type        = string
}

variable "aws_assume_partition" {
  description = "AWS ARN partition for the assume-role policy (\"aws\" for commercial; GovCloud partitions are backlog item #2, not supported yet)."
  type        = string
  default     = "aws"
}

variable "tags" {
  description = "Additional tags merged onto this module's resources."
  type        = map(string)
  default     = {}
}
