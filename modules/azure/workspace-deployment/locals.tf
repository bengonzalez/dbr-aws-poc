locals {
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
}
