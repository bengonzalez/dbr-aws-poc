# Deliberate FORK of modules/unity-catalog-workspace, not a generalization
# of it - keeps the working AWS module untouched (this project's standing
# convention: modules stay single-purpose and simple). Two real,
# spike-validated differences from AWS:
#
# 1. No databricks_metastore_assignment resource at all - Azure
#    auto-enables Unity Catalog and auto-assigns a region/tenant-level
#    metastore on workspace creation. Confirmed directly: a brand-new
#    workspace came up with isUcEnabled: true and `databricks metastores
#    summary` already returning a real, assigned metastore with zero
#    Terraform of our own.
# 2. No provider_config { workspace_id } blocks - this module receives a
#    workspace-URL-scoped `databricks` provider (passed down as the plain
#    default, see infrastructure/workspace-azure/main.tf), which already
#    only ever talks to this one workspace. provider_config exists for
#    AWS's account-level provider to target a specific workspace per
#    resource - there's no account-level provider here to disambiguate.

resource "databricks_catalog" "this" {
  name           = var.workspace_name
  isolation_mode = "ISOLATED"
  storage_root   = var.external_location_url
  comment        = "Managed by Terraform - dedicated catalog for ${var.workspace_name}."
}

# Makes this catalog the default for the workspace, same UX nicety as the
# AWS path.
resource "databricks_default_namespace_setting" "this" {
  namespace {
    value = databricks_catalog.this.name
  }
}

# Optional: grants a named principal full control of the catalog, same
# shape as the AWS path - skipped entirely when not set.
resource "databricks_grants" "this" {
  count = var.catalog_admin_principal != null ? 1 : 0

  catalog = databricks_catalog.this.name

  grant {
    principal  = var.catalog_admin_principal
    privileges = ["ALL_PRIVILEGES"]
  }
}
