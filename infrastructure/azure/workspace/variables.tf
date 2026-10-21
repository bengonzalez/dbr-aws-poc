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
  description = "Azure VNet-injection network inputs - see modules/azure/workspace-network for the three shapes (new VNet / client VNet + new subnets / client VNet + adopted subnets)."

  type = object({
    vpc_cidr                   = optional(string)
    public_subnet_cidr         = optional(string)
    private_subnet_cidr        = optional(string)
    existing_vnet_id           = optional(string)
    existing_public_subnet_id  = optional(string)
    existing_private_subnet_id = optional(string)
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

variable "databricks_account_id" {
  description = "ID of the Azure-linked Databricks account - only needed when network_policy_id is set (the provider block that attaches it requires one, even though most workspaces never set either). Null (default) is harmless when network_policy_id is also null. See infrastructure/azure/account/, CLAUDE.md §10 backlog item #1a / §8 milestone 40."
  type        = string
  default     = null
  sensitive   = true
}

variable "network_policy_id" {
  description = "ID of an account-level Databricks network policy (see infrastructure/aws/account/'s Azure analog, infrastructure/azure/account/) to attach to this workspace. Null (default) leaves the workspace on the account's own un-deletable default-policy, unchanged from today's behavior."
  type        = string
  default     = null
}

variable "log_analytics_workspace_id" {
  description = "ID of the shared Log Analytics workspace (see infrastructure/azure/account/) this workspace's audit logs should be delivered to. Null (default) creates no diagnostic setting at all - audit logging stays off, same as today."
  type        = string
  default     = null
}

variable "audit_log_categories" {
  description = "Databricks workspace diagnostic log categories to enable when log_analytics_workspace_id is set. See modules/azure/workspace-deployment's own variable of the same name for the full description/default."
  type        = list(string)
  default     = ["accounts", "clusters", "dbfs", "jobs", "notebook", "secrets", "sqlPermissions", "ssh", "unityCatalog", "workspace"]
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
