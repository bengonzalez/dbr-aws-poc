# Government-readiness hardening settings (CLAUDE.md §8) - all workspace-
# scoped Databricks-provider settings, applied via the existing account-
# console provider + provider_config { workspace_id }, same pattern every
# Unity Catalog resource in this project already uses. No new provider
# wiring needed.
#
# Compliance Security Profile, Enhanced Security Monitoring, and Automatic
# Cluster Update are gated together behind compliance_standards being
# non-empty - Databricks' own docs confirm enabling CSP auto-enables ESM/
# ACU as a side effect, and all three sit behind the paid "Enhanced
# Security and Compliance" add-on, so making ESM/ACU unconditionally-on
# would silently add billing exposure to every workspace regardless of
# whether anyone asked for compliance hardening.
#
# Legacy-feature disabling has no such billing tie, so it stays
# unconditional (secure by default, matching this project's own
# philosophy of the platform controlling infrastructure specifics rather
# than exposing every SRA toggle as a requester choice).

resource "databricks_compliance_security_profile_workspace_setting" "this" {
  count = length(var.compliance_standards) > 0 ? 1 : 0

  provider = databricks.mws

  compliance_security_profile_workspace {
    is_enabled           = true
    compliance_standards = var.compliance_standards
  }

  provider_config {
    workspace_id = var.databricks_workspace_id
  }
}

resource "databricks_enhanced_security_monitoring_workspace_setting" "this" {
  count = length(var.compliance_standards) > 0 ? 1 : 0

  provider = databricks.mws

  enhanced_security_monitoring_workspace {
    is_enabled = true
  }

  provider_config {
    workspace_id = var.databricks_workspace_id
  }
}

resource "databricks_automatic_cluster_update_workspace_setting" "this" {
  count = length(var.compliance_standards) > 0 ? 1 : 0

  provider = databricks.mws

  automatic_cluster_update_workspace {
    enabled = true
  }

  provider_config {
    workspace_id = var.databricks_workspace_id
  }
}

resource "databricks_disable_legacy_access_setting" "this" {
  provider = databricks.mws

  disable_legacy_access {
    value = true
  }

  provider_config {
    workspace_id = var.databricks_workspace_id
  }
}

resource "databricks_disable_legacy_dbfs_setting" "this" {
  provider = databricks.mws

  disable_legacy_dbfs {
    value = true
  }

  provider_config {
    workspace_id = var.databricks_workspace_id
  }
}
