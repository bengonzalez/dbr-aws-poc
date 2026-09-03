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