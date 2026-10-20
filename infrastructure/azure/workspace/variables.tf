variable "workspace" {
  description = "Resolved workspace configuration."

  type = object({
    name        = string
    environment = string
    isolation   = string
  })

  validation {
    condition     = contains(["dev", "stage", "live"], var.workspace.environment)
    error_message = "workspace.environment must be dev, stage, or live."
  }
}

variable "cloud" {
  description = "Resolved cloud platform configuration."

  type = object({
    provider = string
    region   = string
  })

  validation {
    condition     = var.cloud.provider == "azure"
    error_message = "Only Azure is currently supported by this root."
  }
}

variable "application" {
  description = "Application associated with the workspace."

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
  description = "Azure VNet-injection network inputs - a brand-new, Terraform-owned VNet only (no existing-VNet reuse yet, see modules/azure-workspace-network)."

  type = object({
    vpc_cidr            = string
    public_subnet_cidr  = string
    private_subnet_cidr = string
  })
}

variable "data" {
  description = "Data classification."

  type = object({
    classification = string
  })
}

variable "encryption" {
  description = "Resolved encryption posture. Only platform_managed is supported for Azure today - customer_managed (Key Vault) is an explicitly deferred future enhancement, enforced in resolver/generate_tfvars_azure.py before this ever reaches Terraform."

  type = object({
    workspace        = string
    application_data = string
  })
}

variable "governance" {
  description = "Unity Catalog governance posture."

  type = object({
    unity_catalog     = bool
    workspace_binding = string
  })
}

variable "catalog_admin_principal" {
  description = "A Databricks user name, group name, or service principal application ID to grant ALL_PRIVILEGES on this workspace's catalog. Null skips granting entirely, same as the AWS path."
  type        = string
  default     = null
}

variable "compliance_standards" {
  description = "Regulatory compliance standards this workspace must satisfy (e.g. HIPAA, PCI_DSS, FEDRAMP_MODERATE, FEDRAMP_HIGH, IRAP). Empty (default) leaves Compliance Security Profile, Enhanced Security Monitoring, and Automatic Cluster Update all off."
  type        = list(string)
  default     = []
}

variable "compute" {
  description = "Compute policy."

  type = object({
    policy = string
  })
}

variable "logging" {
  description = "Logging posture."

  type = object({
    level       = string
    centralized = bool
    audit       = bool
  })
}

variable "validation" {
  description = "Validation posture."

  type = object({
    required       = bool
    blocking       = bool
    negative_tests = bool
    evidence       = string
  })
}

variable "tags" {
  description = "Tags applied to every resource this root creates."
  type        = map(string)
  default     = {}
}
