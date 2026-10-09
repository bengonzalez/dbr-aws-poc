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

  # Per-resource ownership, defaulted from network.strategy but overridable
  # independently of it. custom -> existing/reuse; isolated -> terraform/create.
  # Security groups are terraform-owned by default under both strategies.
  vpc_ownership = coalesce(
    var.vpc_ownership_override,
    var.network.strategy == "isolated" ? "terraform" : "existing"
  )

  routing_ownership = coalesce(
    var.routing_ownership_override,
    var.network.strategy == "isolated" ? "terraform" : "existing"
  )

  security_group_ownership = coalesce(
    var.security_group_ownership_override,
    "terraform"
  )

  endpoints_ownership = coalesce(
    var.endpoints_ownership_override,
    var.network.strategy == "isolated" ? "terraform" : "existing"
  )
}