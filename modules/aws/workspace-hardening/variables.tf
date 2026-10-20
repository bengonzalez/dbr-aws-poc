variable "databricks_workspace_id" {
  description = "ID of the already-created Databricks workspace these settings apply to."
  type        = string
}

variable "compliance_standards" {
  description = "Regulatory compliance standards (e.g. HIPAA, PCI_DSS, FEDRAMP_MODERATE, FEDRAMP_HIGH, IRAP - see the Databricks provider's ComplianceStandard enum). Empty (default) leaves Compliance Security Profile, Enhanced Security Monitoring, and Automatic Cluster Update all off, since enabling them incurs the Enhanced Security and Compliance billing add-on."
  type        = list(string)
  default     = []
}
