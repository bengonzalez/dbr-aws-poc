variable "workspace_name" {
  description = "Databricks workspace name."
  type        = string
}

variable "vpc_id" {
  description = "VPC in which to create the endpoints."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block of the VPC, used to scope interface endpoint ingress."
  type        = string
}

variable "aws_region" {
  description = "AWS region hosting the VPC."
  type        = string
}

variable "route_table_ids" {
  description = "Route tables to associate with the S3 gateway endpoint."
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "Private subnets to place interface endpoints in."
  type        = list(string)
}

variable "s3_bucket_arns" {
  description = "S3 bucket ARNs the gateway endpoint policy should allow access to."
  type        = list(string)
}

variable "enable_kms_endpoint" {
  description = "Whether to create a KMS interface endpoint (needed when a customer-managed key is in use)."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags for workspace endpoint resources."
  type        = map(string)
  default     = {}
}
