variable "workspace_name" {
  description = "Unique name of the Databricks workspace. Used to derive resource names."
  type        = string
}

variable "location" {
  description = "Azure region for the VNet/NSG/subnets."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group to create the VNet/NSG/subnets in."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the dedicated VNet - the client's own address-space choice, same role as the AWS path's network.vpc_cidr."
  type        = string
}

variable "public_subnet_cidr" {
  description = "CIDR for the 'public' VNet-injection subnet (Databricks' own naming - no public IP is actually assigned, see no_public_ip on the workspace resource)."
  type        = string
}

variable "private_subnet_cidr" {
  description = "CIDR for the 'private' VNet-injection subnet."
  type        = string
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
