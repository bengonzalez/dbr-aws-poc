module "deployment" {
  source = "../../../modules/azure/workspace-deployment"

  cloud                      = var.cloud
  workspace                  = var.workspace
  application                = var.application
  ownership                  = var.ownership
  network                    = var.network
  encryption                 = var.encryption
  private_link               = var.private_link
  tags                       = local.common_tags
  compliance_standards       = var.compliance_standards
  log_analytics_workspace_id = var.log_analytics_workspace_id
  audit_log_categories       = var.audit_log_categories
}

# Unity Catalog composed here, in the root, rather than inside
# module.deployment - see modules/azure/workspace-deployment/main.tf's
# header comment for why (the workspace-URL-scoped databricks provider
# these modules need must be defined in the root, since it depends on a
# resource module.deployment itself creates).
module "unity_catalog_data" {
  count  = var.governance.unity_catalog ? 1 : 0
  source = "../../../modules/azure/unity-catalog-data"

  providers = {
    databricks = databricks.workspace
  }

  workspace_name       = var.workspace.name
  resource_group_name  = module.deployment.resource_group_name
  location             = var.cloud.region
  storage_account_name = local.storage_account_name
  application_data_key = module.deployment.application_data_key

  application_data_cmk_enabled = var.encryption.application_data == "customer_managed"
  tags                         = local.common_tags
}

module "unity_catalog_workspace" {
  count  = var.governance.unity_catalog ? 1 : 0
  source = "../../../modules/azure/unity-catalog-workspace"

  providers = {
    databricks = databricks.workspace
  }

  workspace_name          = var.workspace.name
  external_location_url   = module.unity_catalog_data[0].external_location_url
  catalog_admin_principal = var.catalog_admin_principal

  depends_on = [
    module.unity_catalog_data
  ]
}

# Government-readiness hardening (CLAUDE.md §8) - legacy-feature disabling,
# unconditional (no billing tie, unlike compliance_standards-gated
# enhanced_security_compliance above). Needs the workspace-scoped
# `databricks` provider this root defines (providers.tf) - same
# provider-placement constraint as Unity Catalog above, so these live here
# rather than inside modules/azure/workspace-deployment.
resource "databricks_disable_legacy_access_setting" "this" {
  provider = databricks.workspace

  disable_legacy_access {
    value = true
  }

  depends_on = [module.deployment]
}

resource "databricks_disable_legacy_dbfs_setting" "this" {
  provider = databricks.workspace

  disable_legacy_dbfs {
    value = true
  }

  depends_on = [module.deployment]
}

# Attaches this workspace to an account-level network policy (CLAUDE.md
# §10 backlog item #1a / §8 milestone 40), when one is resolved for it.
# Needs the account-level provider (databricks.mws, above), not the
# workspace-scoped one everything else in this root uses -
# databricks_workspace_network_option's own docs say it "can only be
# used with an account-level provider." Its own docs also say it
# "cannot be created or deleted," only updated - every workspace always
# has exactly one network policy (default-policy unless changed), so
# this resource just points that association at a different policy
# once the workspace exists.
resource "databricks_workspace_network_option" "this" {
  count = var.network_policy_id != null ? 1 : 0

  provider = databricks.mws

  workspace_id      = module.deployment.workspace_id
  network_policy_id = var.network_policy_id
}
