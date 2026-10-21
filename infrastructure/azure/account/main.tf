module "legacy_features" {
  count  = var.enable_legacy_features ? 1 : 0
  source = "../../../modules/azure/account-legacy-features"

  providers = {
    databricks.mws = databricks.mws
  }
}

module "network_policy" {
  count  = var.enable_network_policy ? 1 : 0
  source = "../../../modules/azure/account-network-policy"

  providers = {
    databricks.mws = databricks.mws
  }

  databricks_account_id         = var.databricks_account_id
  resource_prefix               = var.resource_prefix
  restrict_egress               = var.restrict_egress
  allowed_internet_destinations = var.allowed_internet_destinations
  context_based_ingress_ip_acl  = var.context_based_ingress_ip_acl
}

# Shared audit-log destination (CLAUDE.md §10 backlog item #1a / §8
# milestone 40) - the one genuinely account-wide piece of Azure audit
# logging. Unlike AWS's databricks_mws_log_delivery, creating this alone
# delivers nothing: Azure has no account-level "turn on audit logging
# for every workspace" switch (confirmed from azurerm_monitor_diagnostic_setting's
# own docs - it's always scoped to one target_resource_id). Each
# workspace must separately enable its own diagnostic setting pointed
# at this workspace's id (see modules/azure/workspace-deployment's
# log_analytics_workspace_id variable) - this resource is just the
# shared destination every workspace's setting can point at, mirroring
# AWS's one shared log bucket.
resource "azurerm_resource_group" "audit_log_delivery" {
  count = var.enable_audit_log_delivery ? 1 : 0

  name     = "rg-${var.resource_prefix}-audit-log-delivery"
  location = var.region

  tags = var.tags
}

resource "azurerm_log_analytics_workspace" "audit_log_delivery" {
  count = var.enable_audit_log_delivery ? 1 : 0

  name                = "law-${var.resource_prefix}-audit-logs"
  resource_group_name = azurerm_resource_group.audit_log_delivery[0].name
  location            = var.region

  tags = var.tags
}
