module "deployment" {
  source = "../../../modules/azure/workspace-deployment"

  cloud                = var.cloud
  workspace            = var.workspace
  application          = var.application
  ownership            = var.ownership
  network              = var.network
  tags                 = local.common_tags
  compliance_standards = var.compliance_standards
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
  tags                 = local.common_tags
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
