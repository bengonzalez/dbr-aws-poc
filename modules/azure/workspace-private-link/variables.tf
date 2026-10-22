variable "workspace_name" {
  description = "Unique name of the Databricks workspace. Used to derive resource names."
  type        = string
}

variable "resource_group_name" {
  description = "The workspace's own resource group - where the private endpoints and (when created) the DNS zones go."
  type        = string
}

variable "location" {
  description = "Azure region - must match the workspace."
  type        = string
}

variable "workspace_resource_id" {
  description = "ARM id of the azurerm_databricks_workspace (target of the databricks_ui_api endpoint)."
  type        = string
}

variable "managed_resource_group_name" {
  description = "The workspace's Databricks-managed resource group, where its DBFS storage account lives."
  type        = string
}

variable "virtual_network_id" {
  description = "Workspace VNet - created DNS zones are linked to it."
  type        = string
}

variable "private_endpoint_subnet_id" {
  description = "Dedicated, non-delegated subnet for the three private endpoints."
  type        = string
}

variable "existing_private_dns_zone_ids" {
  description = "Client-provided hub zones, keyed databricks/dfs/blob (privatelink.azuredatabricks.net / privatelink.dfs.core.windows.net / privatelink.blob.core.windows.net). Null (default) creates and links one of each for this workspace - fine for a dedicated VNet, but a second Private Link workspace in the same VNet would collide on the links, so shared/client VNets should bring hub zones."
  type = object({
    databricks = string
    dfs        = string
    blob       = string
  })
  default = null
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
