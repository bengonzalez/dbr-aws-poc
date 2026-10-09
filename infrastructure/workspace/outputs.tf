output "databricks_network_id" {
  description = "Databricks MWS network configuration ID."

  value = databricks_mws_networks.workspace.network_id
}

output "workspace_name" {
  description = "Requested workspace name."
  value       = var.workspace.name
}

output "environment" {
  description = "Workspace environment."
  value       = var.workspace.environment
}

output "application_identifier" {
  description = "Application identifier."
  value       = var.application.identifier
}

output "network_strategy" {
  description = "Network strategy selected for the workspace."
  value       = var.network.strategy
}

output "resolved_vpc_id" {
  description = "VPC used by the workspace."

  value = module.workspace_network.vpc_id
}

output "resolved_private_subnet_ids" {
  description = "Private subnet IDs created for the workspace."

  value = module.workspace_network.private_subnet_ids
}

output "workspace_security_group_id" {
  description = "Security group created for the workspace."

  value = module.workspace_network.security_group_id
}

output "platform_vpc_id" {
  description = "Existing platform VPC used by the workspace."

  value = var.platform.vpc_id
}

output "platform_route_table_ids" {
  description = "Existing route tables used by the workspace."

  value = var.platform.route_table_ids
}

output "network_requirements" {
  description = "Network requirements for the workspace."
  value       = var.network
}

output "workspace_configuration" {
  description = "Resolved workspace configuration used by the factory."
  value = {
    workspace = var.workspace
    cloud = {
      provider = var.cloud.provider
      region   = var.cloud.region
      account  = data.aws_caller_identity.current.account_id
    }
    application = var.application
    ownership   = var.ownership
    network     = var.network
    data        = var.data
    encryption  = var.encryption
    governance  = var.governance
    compute     = var.compute
    logging     = var.logging
    validation  = var.validation
    tags        = local.common_tags
  }
}