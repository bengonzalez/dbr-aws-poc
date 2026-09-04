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

variable "aws_region" {
  description = "AWS region where the endpoints are deployed"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs where interface endpoints will be deployed"
  type        = list(string)
}

variable "vpc_cidr" {
  description = "CIDR block allowed to access interface VPC endpoints"
  type        = string
}