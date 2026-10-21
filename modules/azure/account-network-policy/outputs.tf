output "network_policy_id" {
  description = "ID of the created network policy. Paste this into platform/inventory/aws.yaml's databricks.accounts.<id>.network_policy_id so resolver/generate_tfvars.py can pick it up automatically for workspaces that opt in."
  value       = databricks_account_network_policy.this.network_policy_id
}
