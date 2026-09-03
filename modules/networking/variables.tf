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
