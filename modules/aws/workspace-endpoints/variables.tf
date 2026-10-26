variable "workspace_name" {
  description = "Databricks workspace name."
  type        = string
}

variable "vpc_id" {
  description = "VPC in which to create the endpoints."
  type        = string
}

variable "workspace_security_group_id" {
  description = "The workspace's compute security group, used as the ingress source for the interface endpoint security group."
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

variable "interface_endpoint_subnet_ids" {
  description = "Subnets to place interface endpoints in (e.g. a client's backend tier). Null places them in private_subnet_ids."
  type        = list(string)
  default     = null
}

variable "existing_s3_gateway_endpoint_id" {
  description = "ID of an existing S3 gateway endpoint already attached to the compute route tables. Null creates one."
  type        = string
  default     = null
}

variable "existing_sts_endpoint_id" {
  description = "ID of an existing STS interface endpoint in the VPC. Null creates one."
  type        = string
  default     = null
}

variable "existing_kms_endpoint_id" {
  description = "ID of an existing KMS interface endpoint in the VPC. Null creates one (when enable_kms_endpoint)."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags for workspace endpoint resources."
  type        = map(string)
  default     = {}
}
