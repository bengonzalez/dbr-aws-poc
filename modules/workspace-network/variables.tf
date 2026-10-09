variable "workspace_name" {
  description = "Databricks workspace name."
  type        = string
}

variable "vpc_id" {
  description = "Existing VPC ID."
  type        = string
}

variable "private_subnets" {
  description = "Private subnets to create for the workspace."

  type = list(object({
    cidr              = string
    availability_zone = string
  }))

  validation {
    condition     = length(var.private_subnets) >= 2
    error_message = "At least two private subnets are required."
  }
}

variable "route_table_ids" {
  description = "Existing route tables to associate with the workspace subnets."

  type = list(string)

  validation {
    condition     = length(var.route_table_ids) >= 2
    error_message = "At least two route tables are required."
  }

  validation {
    condition = (
      length(var.route_table_ids) == length(var.private_subnets)
    )

    error_message = "The number of route tables must match the number of private subnets."
  }
}

variable "tags" {
  description = "Tags for workspace network resources."
  type        = map(string)
  default     = {}
}