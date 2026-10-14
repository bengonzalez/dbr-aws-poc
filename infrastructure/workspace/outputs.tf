output "databricks_network_id" {
  description = "Databricks MWS network configuration ID."
  value       = module.deployment.databricks_network_id
}

output "databricks_workspace_id" {
  description = "Databricks workspace ID."
  value       = module.deployment.databricks_workspace_id
}

output "databricks_workspace_url" {
  description = "URL of the provisioned Databricks workspace."
  value       = module.deployment.databricks_workspace_url
}

output "workspace_name" {
  description = "Requested workspace name."
  value       = module.deployment.workspace_name
}

output "environment" {
  description = "Workspace environment."
  value       = module.deployment.environment
}

output "application_identifier" {
  description = "Application identifier."
  value       = module.deployment.application_identifier
}

output "network_strategy" {
  description = "Network strategy selected for the workspace."
  value       = module.deployment.network_strategy
}

output "resolved_vpc_id" {
  description = "VPC used by the workspace."
  value       = module.deployment.resolved_vpc_id
}

output "resolved_private_subnet_ids" {
  description = "Private subnet IDs created for the workspace."
  value       = module.deployment.resolved_private_subnet_ids
}

output "workspace_security_group_id" {
  description = "Security group created for the workspace."
  value       = module.deployment.workspace_security_group_id
}

output "platform_vpc_id" {
  description = "Existing platform VPC used by the workspace."
  value       = module.deployment.platform_vpc_id
}

output "platform_route_table_ids" {
  description = "Existing route tables used by the workspace."
  value       = module.deployment.platform_route_table_ids
}

output "network_requirements" {
  description = "Network requirements for the workspace."
  value       = module.deployment.network_requirements
}

output "workspace_cross_account_role_name" {
  description = "Workspace-specific Databricks cross-account IAM role name."
  value       = module.deployment.workspace_cross_account_role_name
}

output "workspace_cross_account_role_arn" {
  description = "Workspace-specific Databricks cross-account IAM role ARN."
  value       = module.deployment.workspace_cross_account_role_arn
}

output "workspace_storage_kms_key_arn" {
  description = "ARN of the customer-managed KMS key for workspace storage, when encryption.workspace is customer_managed; null otherwise."
  value       = module.deployment.workspace_storage_kms_key_arn
}

output "managed_services_kms_key_arn" {
  description = "ARN of the customer-managed KMS key for Databricks managed services, when encryption.workspace is customer_managed; null otherwise."
  value       = module.deployment.managed_services_kms_key_arn
}

output "workspace_configuration" {
  description = "Resolved workspace configuration used by the factory."
  value       = module.deployment.workspace_configuration
}

output "unity_catalog_name" {
  description = "Name of the Unity Catalog catalog created for this workspace, when governance.unity_catalog is true; null otherwise."
  value       = module.deployment.unity_catalog_name
}

output "unity_catalog_external_location_name" {
  description = "Name of the Unity Catalog external location backing this workspace's catalog, when governance.unity_catalog is true; null otherwise."
  value       = module.deployment.unity_catalog_external_location_name
}
