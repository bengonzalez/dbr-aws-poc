# Account-level legacy-feature disabling - direct port of
# modules/aws/account-legacy-features (CLAUDE.md §10 backlog item #1a /
# §8 milestone 40). This Databricks-provider resource has no
# cloud-specific schema at all (confirmed from the provider's own docs),
# so the Azure version is identical to the AWS one apart from which
# provider host/account_id the root passes in.

resource "databricks_disable_legacy_features_setting" "this" {
  provider = databricks.mws

  disable_legacy_features {
    value = true
  }
}
