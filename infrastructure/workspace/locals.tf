locals {
  workspace_name = var.workspace.name

  environment = var.workspace.environment

  application_identifier = var.application.identifier

  name_prefix = var.workspace.name

  common_tags = merge(
    var.tags,
    {
      ManagedBy   = "terraform"
      Platform    = "databricks"
      Environment = var.workspace.environment
      Workspace   = var.workspace.name
      Application = var.application.identifier
    }
  )

  resolved_network = {
    strategy           = var.network.strategy
    architecture       = var.network.architecture
    vpc_id             = try(var.network.vpc_id, null)
    private_subnet_ids = try(var.network.private_subnet_ids, [])
    security_group_id  = try(var.network.security_group_id, null)
  }
}