output "workspace_id" {
  value = module.deployment.workspace_id
}

output "workspace_url" {
  value = "https://${module.deployment.workspace_url}"
}

output "resource_group_name" {
  value = module.deployment.resource_group_name
}

output "catalog_name" {
  value = var.governance.unity_catalog ? module.unity_catalog_workspace[0].catalog_name : null
}

# Both read by resolver/validate_deployment_azure.py (CLAUDE.md §8
# milestone 43), so it never recomputes resource names by convention.
output "workspace_resource_id" {
  value = module.deployment.workspace_resource_id
}

output "unity_catalog_storage_account_name" {
  value = var.governance.unity_catalog ? local.storage_account_name : null
}
