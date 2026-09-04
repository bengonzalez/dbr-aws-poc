variable "project_name" {
  description = "Name of the project"
  type        = string
}

variable "kms_key_arn" {
  description = "ARN of the KMS key used by the project"
  type        = string
}

variable "data_bucket_arn" {
  description = "ARN of the S3 data bucket"
  type        = string
}

variable "databricks_account_id" {
  description = "Databricks account ID used as the external ID"
  type        = string
  sensitive   = true
}

variable "aws_region" {
  description = "AWS region where the Databricks workspace will run"
  type        = string
}

variable "vpc_id" {
  description = "ID of the VPC used by the Databricks workspace"
  type        = string
}

variable "databricks_security_group_id" {
  description = "Security group ID used by the Databricks workspace"
  type        = string
}