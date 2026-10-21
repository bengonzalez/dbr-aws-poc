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

variable "compliance_standards" {
  description = "Regulatory compliance standards this workspace must satisfy (e.g. HIPAA, PCI_DSS, FEDRAMP_MODERATE, FEDRAMP_HIGH, IRAP). Empty (default) leaves Compliance Security Profile, Enhanced Security Monitoring, and Automatic Cluster Update all off."
  type        = list(string)
  default     = []
}

variable "log_analytics_workspace_id" {
  description = "ID of the shared Log Analytics workspace (see infrastructure/azure/account/, CLAUDE.md §10 backlog item #1a / §8 milestone 40) this workspace's audit logs should be delivered to. Null (default) creates no azurerm_monitor_diagnostic_setting at all - audit logging stays off, same as today."
  type        = string
  default     = null
}

variable "audit_log_categories" {
  description = "Databricks workspace diagnostic log categories to enable when log_analytics_workspace_id is set (confirmed against Microsoft's own current reference table, not guessed - category_group shortcuts like \"allLogs\" are not confirmed supported for this resource type). Default covers the categories that map most directly to AWS's broad AUDIT_LOGS log type."
  type        = list(string)
  default     = ["accounts", "clusters", "dbfs", "jobs", "notebook", "secrets", "sqlPermissions", "ssh", "unityCatalog", "workspace"]
}
