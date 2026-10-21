variable "region" {
  description = "Azure region hosting the shared audit-log-delivery Log Analytics workspace."
  type        = string
}

variable "databricks_account_id" {
  description = "ID of the Azure-linked Databricks account these account-level settings apply to. Discovered via an interactive `databricks auth login --host https://accounts.azuredatabricks.net` - see CLAUDE.md §10 backlog item #1a / §8 milestone 40."
  type        = string
  sensitive   = true
}

variable "resource_prefix" {
  description = "Prefix for every resource this root creates (resource group/Log Analytics workspace/policy names)."
  type        = string
}

# Each feature is independently toggled and defaults to false - same
# reasoning as infrastructure/aws/account/ (CLAUDE.md §8 milestone 39):
# these are account-wide, and disable_legacy_features is very likely a
# one-way lock once enabled, so this root is a no-op until an operator
# deliberately opts in.

variable "enable_legacy_features" {
  description = "Enable account-level legacy-feature disabling for every workspace created on this account from now on."
  type        = bool
  default     = false
}

variable "enable_network_policy" {
  description = "Create the account-level network policy. Workspaces must still opt in explicitly via their own network_policy_id - creating this policy alone changes nothing for any existing workspace."
  type        = bool
  default     = false
}

variable "restrict_egress" {
  description = "Passed through to modules/azure/account-network-policy. Only relevant when enable_network_policy is true. Governs serverless-workload egress only - no effect on this factory's classic, VNet-injected compute."
  type        = bool
  default     = false
}

variable "allowed_internet_destinations" {
  description = "Passed through to modules/azure/account-network-policy. Only relevant when enable_network_policy and restrict_egress are both true."
  type        = list(string)
  default     = []
}

variable "context_based_ingress_ip_acl" {
  description = "Passed through to modules/azure/account-network-policy. IP/CIDR allow-list for public access to a referencing workspace. Verify every entry before setting this - a wrong range can lock out account/workspace console access."
  type        = list(string)
  default     = []
}

variable "enable_audit_log_delivery" {
  description = "Create the shared Log Analytics workspace audit logs are delivered to. Unlike AWS, this alone delivers nothing - each workspace must also enable its own azurerm_monitor_diagnostic_setting pointed at this destination (see modules/azure/workspace-deployment's log_analytics_workspace_id variable) - see this root's own module.audit_log_destination comment."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Additional tags merged onto every resource this root creates."
  type        = map(string)
  default     = {}
}
