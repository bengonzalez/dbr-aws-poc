variable "cloud" {
  description = "Resolved cloud platform configuration. Same shape as the AWS root's - no explicit account/subscription id variable; the azurerm provider derives it from whatever Azure CLI session is active, same posture as the AWS provider deriving its account from active credentials."

  type = object({
    provider = string
    region   = string
  })

  validation {
    condition     = var.cloud.provider == "azure"
    error_message = "Only Azure is supported by this module."
  }
}

variable "workspace" {
  description = "Workspace name/environment/isolation."
  type = object({
    name        = string
    environment = string
    isolation   = string
  })
}

variable "application" {
  description = "Application name/identifier."
  type = object({
    name       = string
    identifier = string
  })
}

variable "ownership" {
  description = "Technical/business owner."
  type = object({
    technical_owner = string
    business_owner  = string
  })
}

variable "network" {
  description = "Azure VNet-injection network inputs - a brand-new, Terraform-owned VNet only (no existing-VNet reuse yet)."
  type = object({
    vpc_cidr            = string
    public_subnet_cidr  = string
    private_subnet_cidr = string
  })
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
