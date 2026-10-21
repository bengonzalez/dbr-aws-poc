variable "workspace_name" {
  description = "Unique name of the Databricks workspace. Used to derive resource names."
  type        = string
}

variable "location" {
  description = "Azure region for the VNet/NSG/subnets."
  type        = string
}

variable "resource_group_name" {
  description = "The workspace's own resource group - where a new VNet (isolated) and the NSG are created. Subnets created inside a client-provided VNet go in that VNet's resource group instead."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for a new, dedicated VNet - the client's own address-space choice, same role as the AWS path's network.vpc_cidr. Required when existing_vnet_id is null; ignored otherwise."
  type        = string
  default     = null

  validation {
    condition     = var.existing_vnet_id != null || var.vpc_cidr != null
    error_message = "vpc_cidr is required when existing_vnet_id is not set (a new VNet is being created)."
  }
}

variable "existing_vnet_id" {
  description = "Full Azure resource id of a client-provided VNet to reuse (custom strategy). Null (default) creates a new VNet. Must be in the same subscription as the workspace."
  type        = string
  default     = null

  validation {
    condition     = var.existing_vnet_id == null || can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.Network/virtualNetworks/[^/]+$", var.existing_vnet_id))
    error_message = "existing_vnet_id must be a full Azure VNet resource id (/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<name>)."
  }
}

variable "public_subnet_cidr" {
  description = "CIDR for the 'public' VNet-injection subnet (Databricks' own naming - no public IP is actually assigned, see no_public_ip on the workspace resource). Required unless adopting existing subnets."
  type        = string
  default     = null

  validation {
    condition     = var.existing_public_subnet_id != null || var.public_subnet_cidr != null
    error_message = "public_subnet_cidr is required unless existing_public_subnet_id is set."
  }
}

variable "private_subnet_cidr" {
  description = "CIDR for the 'private' VNet-injection subnet. Required unless adopting existing subnets."
  type        = string
  default     = null

  validation {
    # Keyed off existing_public_subnet_id, not the private one - the public
    # id alone is the module's adopt-vs-create switch (local.create_subnets).
    condition     = var.existing_public_subnet_id != null || var.private_subnet_cidr != null
    error_message = "private_subnet_cidr is required unless adopting existing subnets (existing_public_subnet_id + existing_private_subnet_id)."
  }
}

variable "existing_public_subnet_id" {
  description = "Full Azure resource id of an existing subnet inside existing_vnet_id to adopt as the 'public' subnet. Must already be delegated to Microsoft.Databricks/workspaces and have an NSG associated. Set together with existing_private_subnet_id, or neither."
  type        = string
  default     = null

  validation {
    condition = var.existing_public_subnet_id == null || (
      var.existing_vnet_id != null &&
      var.existing_private_subnet_id != null &&
      startswith(lower(coalesce(var.existing_public_subnet_id, "-")), "${lower(coalesce(var.existing_vnet_id, "-"))}/subnets/")
    )
    error_message = "existing_public_subnet_id requires existing_vnet_id and existing_private_subnet_id, and must be a subnet of existing_vnet_id."
  }
}

# (public set, private null) is caught above; (private set, public null)
# means "create", so private_subnet_cidr's own validation then fails
# unless a CIDR was given.

variable "existing_private_subnet_id" {
  description = "Full Azure resource id of an existing subnet inside existing_vnet_id to adopt as the 'private' subnet. Same requirements as existing_public_subnet_id."
  type        = string
  default     = null

  validation {
    # The "set both or neither" pairing is checked once, on
    # existing_public_subnet_id - checking it from both sides is a
    # validation cycle Terraform rejects.
    condition = var.existing_private_subnet_id == null || (
      var.existing_vnet_id != null &&
      startswith(lower(coalesce(var.existing_private_subnet_id, "-")), "${lower(coalesce(var.existing_vnet_id, "-"))}/subnets/")
    )
    error_message = "existing_private_subnet_id requires existing_vnet_id and must be a subnet of it."
  }
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
