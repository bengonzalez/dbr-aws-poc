variable "project_name" {
  description = "Name of the project"
  type        = string
}

variable "vpc_id" {
  description = "ID of the VPC where the endpoint will be created"
  type        = string
}

variable "route_table_ids" {
  description = "Route tables that should use the S3 VPC endpoint"
  type        = list(string)
}