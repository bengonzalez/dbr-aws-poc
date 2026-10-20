
variable "workspace_name" {
  description = "Unique name of the Databricks workspace."
  type        = string
}

variable "databricks_account_id" {
  description = "Databricks account ID used as the IAM trust external ID."
  type        = string
  sensitive   = true
}

variable "tags" {
  description = "Tags applied to workspace IAM resources."
  type        = map(string)
  default     = {}
}

variable "aws_account_id" {
  description = "AWS account ID hosting the workspace."
  type        = string
}

variable "aws_region" {
  description = "AWS region hosting the workspace."
  type        = string
}

variable "vpc_id" {
  description = "VPC in which Databricks workspace resources will run."
  type        = string
}

variable "databricks_security_group_id" {
  description = "Workspace security group to restrict Databricks permissions."
  type        = string
}