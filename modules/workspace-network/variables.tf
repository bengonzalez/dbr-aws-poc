variable "workspace_name" {
  description = "Databricks workspace name."
  type        = string
}

variable "existing_vpc_id" {
  description = "ID of an existing VPC to use. Null creates a new VPC using vpc_cidr."
  type        = string
  default     = null
}

variable "vpc_cidr" {
  description = "CIDR block for a new VPC. Required when existing_vpc_id is null."
  type        = string
  default     = null

  validation {
    condition     = var.existing_vpc_id != null || var.vpc_cidr != null
    error_message = "vpc_cidr is required when existing_vpc_id is not set."
  }
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

variable "existing_route_table_ids" {
  description = "IDs of existing route tables to associate with the workspace subnets. Null creates new route tables (local route only, no NAT/IGW)."
  type        = list(string)
  default     = null

  validation {
    condition = (
      var.existing_route_table_ids == null ||
      length(var.existing_route_table_ids) == length(var.private_subnets)
    )

    error_message = "When provided, the number of existing route tables must match the number of private subnets."
  }
}

variable "existing_security_group_id" {
  description = "ID of an existing security group to use for the workspace. Null creates a new one."
  type        = string
  default     = null
}

variable "nat_enabled" {
  description = "Whether to build a NAT Gateway fallback for full control-plane/internet connectivity (used when Databricks PrivateLink isn't available). Only takes effect when this module is also creating the VPC (existing_vpc_id is null) - attaching an Internet Gateway and modifying route tables for a VPC this factory doesn't own isn't this module's call to make."
  type        = bool
  default     = false
}

variable "nat_subnet_cidr" {
  description = "CIDR block for the NAT Gateway's public subnet. Required when nat_enabled is true and existing_vpc_id is null."
  type        = string
  default     = null

  validation {
    condition     = !var.nat_enabled || var.existing_vpc_id != null || var.nat_subnet_cidr != null
    error_message = "nat_subnet_cidr is required when nat_enabled is true and a new VPC is being created."
  }
}

variable "tags" {
  description = "Tags for workspace network resources."
  type        = map(string)
  default     = {}
}
