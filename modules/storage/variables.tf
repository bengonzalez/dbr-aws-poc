variable "project_name" {
  description = "Name of the project"
  type        = string
}

variable "kms_key_arn" {
  description = "ARN of the KMS key used to encrypt the S3 bucket"
  type        = string
}

variable "bucket_suffix" {
  description = "Unique suffix used to ensure the S3 bucket name is globally unique"
  type        = string
}