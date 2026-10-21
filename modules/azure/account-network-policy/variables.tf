variable "databricks_account_id" {
  description = "ID of the Databricks account this policy applies to."
  type        = string
}

variable "resource_prefix" {
  description = "Prefix for the policy's own id (must not exceed 32 characters per the provider's own constraint)."
  type        = string
}

variable "restrict_egress" {
  description = "When true, workspaces referencing this policy can only reach the internet destinations in allowed_internet_destinations (RESTRICTED_ACCESS). When false (default), egress is unrestricted - matches every existing workspace's current, unrestricted behavior. Real lockout risk if flipped on without a correct allow-list - see CLAUDE.md §10."
  type        = bool
  default     = false
}

variable "allowed_internet_destinations" {
  description = "DNS names allowed through egress when restrict_egress is true. Ignored otherwise. No Security Analysis Tool (SAT) defaults are pre-populated here - see CLAUDE.md §10 backlog item #5."
  type        = list(string)
  default     = []
}

variable "context_based_ingress_ip_acl" {
  description = "Optional list of IP addresses/CIDRs allowed to reach a referencing workspace's public endpoint. Empty (default) applies no IP-based ingress restriction (FULL_ACCESS)."
  type        = list(string)
  default     = []
}
