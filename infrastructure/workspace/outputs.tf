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
  description = "Resolved VPC ID."
  value       = try(var.network.vpc_id, null)
}

output "resolved_private_subnet_ids" {
  description = "Resolved private subnet IDs."
  value       = try(var.network.private_subnet_ids, [])
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