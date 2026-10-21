output "network_policy_id" {
  description = "ID of the created network policy, or null when enable_network_policy is false. Paste a non-null value into platform/inventory/azure.yaml's azure.accounts.<name>.network_policy_id to make it the auto-looked-up default for new workspaces."
  value       = var.enable_network_policy ? module.network_policy[0].network_policy_id : null
}

output "log_analytics_workspace_id" {
  description = "ID of the shared Log Analytics workspace audit logs are delivered to, or null when enable_audit_log_delivery is false. Paste a non-null value into platform/inventory/azure.yaml's azure.accounts.<name>.log_analytics_workspace_id - each workspace still needs its own log_analytics_workspace_id override/auto-lookup to actually enable delivery (see modules/azure/workspace-deployment)."
  value       = var.enable_audit_log_delivery ? azurerm_log_analytics_workspace.audit_log_delivery[0].id : null
}
