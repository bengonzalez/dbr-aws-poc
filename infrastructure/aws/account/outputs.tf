output "network_policy_id" {
  description = "ID of the created network policy, or null when enable_network_policy is false. Paste a non-null value into platform/inventory/aws.yaml's databricks.accounts.<id>.network_policy_id to make it the auto-looked-up default for new workspaces."
  value       = var.enable_network_policy ? module.network_policy[0].network_policy_id : null
}

output "audit_log_bucket_name" {
  description = "S3 bucket audit logs are delivered to, or null when enable_audit_log_delivery is false."
  value       = var.enable_audit_log_delivery ? module.audit_log_delivery[0].log_bucket_name : null
}
