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

  network_requirements = var.network
}