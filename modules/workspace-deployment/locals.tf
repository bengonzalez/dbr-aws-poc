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

  # Decoupled from endpoints_ownership: Databricks PrivateLink requires an
  # Enterprise-tier Databricks account, which not every account has. Defaults
  # to "on whenever endpoints are terraform-owned" (same as before this was
  # split out), but can be turned off independently so the generic AWS
  # service endpoints (S3/STS/KMS) still get built on accounts where
  # PrivateLink itself isn't available.
  privatelink_enabled = coalesce(
    var.privatelink_enabled_override,
    local.endpoints_ownership == "terraform"
  )

  # NAT Gateway fallback for accounts without PrivateLink - resolver/
  # generate_tfvars.py normally sets nat_enabled_override explicitly
  # (from network.connectivity, §8 milestone 27), so this default (off)
  # rarely matters in practice; it's still the safe choice if this
  # variable is ever set directly, bypassing the generator (no surprise
  # NAT Gateway / internet egress / hourly cost). Only takes effect when
  # VPC ownership resolves to "terraform" - see modules/workspace-network.
  nat_enabled = coalesce(
    var.nat_enabled_override,
    false
  )
}
