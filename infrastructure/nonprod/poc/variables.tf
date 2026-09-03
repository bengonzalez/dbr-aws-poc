variable "aws_region" {
  description = "AWS region for the POC"
  type        = string
  default     = "us-east-1"
}
variable "project_name" {
  description = "Name used to identify resources"
  type        = string
  default     = "databricks-poc"
}

variable "vpc_cidr" {
  description = "CIDR block for the POC VPC"
  type        = string
  default     = "10.20.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet"
  type        = string
  default     = "10.20.1.0/24"
}

variable "private_subnet_cidr" {
  description = "CIDR block for the private subnet"
  type        = list(string)
  default     = ["10.20.10.0/24", "10.20.11.0/24"]
}

variable "bucket_suffix" {
  description = "Unique suffix for globally unique AWS resource names"
  type        = string
}