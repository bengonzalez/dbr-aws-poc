# Account-level legacy-feature disabling (Hive Metastore, DBFS, no-
# isolation shared clusters) for every workspace CREATED AFTER this is
# enabled on the account - distinct from the workspace-scoped
# disable_legacy_access/disable_legacy_dbfs settings in
# modules/aws/workspace-hardening, which only ever affect one already-
# existing workspace. CLAUDE.md §10 backlog item #1 / §8 milestone 39.
#
# No count/toggle here - this module's own existence is the toggle,
# gated by infrastructure/aws/account/main.tf's enable_legacy_features
# variable instead, same as the other two account-level modules.
#
# Like the workspace-scoped equivalents (CLAUDE.md §8 milestone 38),
# this setting is expected to be one-way/locked once enabled - not yet
# confirmed against a real account, since this module is plan-verified
# only in this pass (see CLAUDE.md §10).

resource "databricks_disable_legacy_features_setting" "this" {
  provider = databricks.mws

  disable_legacy_features {
    value = true
  }
}
