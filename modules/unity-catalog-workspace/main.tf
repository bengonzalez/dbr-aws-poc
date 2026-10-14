
# Assigns the existing, platform-owned metastore to this workspace. Not
# automatic: two unrelated pre-existing workspaces checked during design
# (different regions) confirmed assignment doesn't happen on its own.
resource "databricks_metastore_assignment" "this" {
  provider = databricks.mws

  metastore_id = var.existing_metastore_id
  workspace_id = var.databricks_workspace_id
}

# A dedicated, isolated catalog per workspace - always isolated regardless
# of environment (see CLAUDE.md Sec8's Unity Catalog milestone for why
# governance.workspace_binding's differentiated values aren't consumed
# here: defaulting non-"required" environments to OPEN would make their
# catalogs visible account-wide by default, which wasn't decided lightly).
resource "databricks_catalog" "this" {
  provider = databricks.mws

  name           = var.workspace_name
  isolation_mode = "ISOLATED"
  storage_root   = "s3://${var.uc_bucket_name}/"
  comment        = "Managed by Terraform - dedicated catalog for ${var.workspace_name}."

  provider_config {
    workspace_id = var.databricks_workspace_id
  }

  depends_on = [
    databricks_metastore_assignment.this
  ]
}

# Makes this catalog the default for the workspace, so SQL users don't need
# `USE CATALOG <name>` before querying - a UX nicety, not core governance.
resource "databricks_default_namespace_setting" "this" {
  provider = databricks.mws

  namespace {
    value = databricks_catalog.this.name
  }

  provider_config {
    workspace_id = var.databricks_workspace_id
  }
}

# Optional: grants a named principal full control of the catalog. Skipped
# entirely when not set - catalog owner then defaults to whoever runs
# terraform apply, same as before this existed. This resource is
# authoritative (it replaces the catalog's whole grant set), so it only
# ever grants this one principal - no partial/additive grants here.
resource "databricks_grants" "this" {
  count = var.catalog_admin_principal != null ? 1 : 0

  provider = databricks.mws

  catalog = databricks_catalog.this.name

  grant {
    principal  = var.catalog_admin_principal
    privileges = ["ALL_PRIVILEGES"]
  }

  provider_config {
    workspace_id = var.databricks_workspace_id
  }
}
