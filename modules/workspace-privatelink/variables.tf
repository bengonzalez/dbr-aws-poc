variable "workspace_name" {
  description = "Databricks workspace name."
  type        = string
}

variable "databricks_account_id" {
  description = "Databricks account ID used to register the VPC endpoints and private access settings."
  type        = string
  sensitive   = true
}

variable "aws_region" {
  description = "AWS region hosting the VPC (also the region recorded against the Databricks VPC endpoint registrations)."
  type        = string
}

variable "vpc_id" {
  description = "VPC in which to create the PrivateLink interface endpoints."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnets to place the PrivateLink interface endpoints in."
  type        = list(string)
}

variable "workspace_security_group_id" {
  description = "The workspace's compute security group, used as the ingress source for the PrivateLink security group."
  type        = string
}

variable "tags" {
  description = "Tags for PrivateLink resources."
  type        = map(string)
  default     = {}
}
