module "legacy_features" {
  count  = var.enable_legacy_features ? 1 : 0
  source = "../../../modules/aws/account-legacy-features"

  providers = {
    databricks.mws = databricks.mws
  }
}

module "network_policy" {
  count  = var.enable_network_policy ? 1 : 0
  source = "../../../modules/aws/account-network-policy"

  providers = {
    databricks.mws = databricks.mws
  }

  databricks_account_id         = var.databricks_account_id
  resource_prefix               = var.resource_prefix
  restrict_egress               = var.restrict_egress
  allowed_internet_destinations = var.allowed_internet_destinations
  context_based_ingress_ip_acl  = var.context_based_ingress_ip_acl
}

module "audit_log_delivery" {
  count  = var.enable_audit_log_delivery ? 1 : 0
  source = "../../../modules/aws/account-audit-log-delivery"

  providers = {
    aws            = aws
    databricks.mws = databricks.mws
  }

  databricks_account_id = var.databricks_account_id
  resource_prefix       = var.resource_prefix
  tags                  = var.tags
}
