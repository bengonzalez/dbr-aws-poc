variable "region" {
  description = "AWS region hosting the audit-log-delivery S3 bucket."
  type        = string
}

variable "databricks_account_id" {
  description = "ID of the Databricks account these account-level settings apply to."
  type        = string
  sensitive   = true
}

variable "databricks_profile" {
  description = "Databricks CLI account-console authentication profile."
  type        = string
}

variable "resource_prefix" {
  description = "Prefix for every resource this root creates (bucket/role/credential/policy names)."
  type        = string
}

# Each feature is independently toggled and defaults to false - this root
# is a no-op until an operator deliberately opts in. See CLAUDE.md §10
# backlog item #1 / §8 milestone 39 for why these default differently
# from the workspace-level hardening module (modules/aws/workspace-hardening),
# which left its equivalent legacy-feature disables unconditional:
# account-level settings here affect every current AND future workspace
# on the account, and disable_legacy_features is expected to be a
# one-way lock once enabled (not yet confirmed against a real account).

variable "enable_legacy_features" {
  description = "Enable account-level legacy-feature disabling (Hive Metastore, DBFS, no-isolation shared clusters) for every workspace created on this account from now on."
  type        = bool
  default     = false
}

variable "enable_network_policy" {
  description = "Create the account-level network policy. Workspaces must still opt in explicitly via their own network_policy_id (see resolver/inventory.py::resolve_network_policy_id()) - creating this policy alone changes nothing for any existing workspace."
  type        = bool
  default     = false
}

variable "restrict_egress" {
  description = "Passed through to modules/aws/account-network-policy. Only relevant when enable_network_policy is true. Governs serverless-workload egress only - no effect on this factory's classic, VPC-injected compute. See that module's own comments."
  type        = bool
  default     = false
}

variable "allowed_internet_destinations" {
  description = "Passed through to modules/aws/account-network-policy. Only relevant when enable_network_policy and restrict_egress are both true."
  type        = list(string)
  default     = []
}

variable "context_based_ingress_ip_acl" {
  description = "Passed through to modules/aws/account-network-policy. IP/CIDR allow-list for public access to a referencing workspace. Verify every entry before setting this - a wrong range can lock out account/workspace console access."
  type        = list(string)
  default     = []
}

variable "enable_audit_log_delivery" {
  description = "Enable account-level audit log delivery to a dedicated S3 bucket."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Additional tags merged onto every resource this root creates."
  type        = map(string)
  default     = {}
}
