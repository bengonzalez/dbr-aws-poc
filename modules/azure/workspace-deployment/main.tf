# Network + workspace creation only - deliberately does NOT compose Unity
# Catalog modules the way modules/aws/workspace-deployment does for AWS.
# Reason: the databricks provider Unity Catalog needs is workspace-URL
# scoped (host = this module's own azurerm_databricks_workspace.this.
# workspace_url), and Terraform does not allow a non-root module to define
# its own provider block referencing a resource it creates - providers
# that depend on a resource's computed output must live in the ROOT module.
# So the shared root (infrastructure/azure/workspace) defines that provider
# itself, referencing this module's workspace_url output, and composes the
# Unity Catalog modules directly - see its main.tf/providers.tf.

resource "azurerm_resource_group" "this" {
  name     = "rg-${var.workspace.name}"
  location = var.cloud.region

  tags = local.common_tags
}

module "network" {
  source = "../workspace-network"

  workspace_name             = var.workspace.name
  location                   = var.cloud.region
  resource_group_name        = azurerm_resource_group.this.name
  vpc_cidr                   = var.network.vpc_cidr
  public_subnet_cidr         = var.network.public_subnet_cidr
  private_subnet_cidr        = var.network.private_subnet_cidr
  existing_vnet_id           = var.network.existing_vnet_id
  existing_public_subnet_id  = var.network.existing_public_subnet_id
  existing_private_subnet_id = var.network.existing_private_subnet_id
  tags                       = local.common_tags

  private_endpoint_subnet_cidr = var.private_link.enabled ? var.network.private_endpoint_subnet_cidr : null
}

locals {
  workspace_cmk_enabled        = var.encryption.workspace == "customer_managed"
  application_data_cmk_enabled = var.encryption.application_data == "customer_managed"
}

# Customer-managed keys (CLAUDE.md §8 milestone 42). Called whenever either
# encryption setting is customer_managed - the application_data key is
# consumed by the root's Unity Catalog storage account, not here (see
# outputs.tf).
module "kms" {
  count  = local.workspace_cmk_enabled || local.application_data_cmk_enabled ? 1 : 0
  source = "../workspace-kms"

  workspace_name                    = var.workspace.name
  resource_group_name               = azurerm_resource_group.this.name
  location                          = var.cloud.region
  workspace_cmk_enabled             = local.workspace_cmk_enabled
  application_data_cmk_enabled      = local.application_data_cmk_enabled
  existing_workspace_storage_key_id = var.encryption.existing_workspace_storage_key_id
  existing_managed_services_key_id  = var.encryption.existing_managed_services_key_id
  existing_application_data_key_id  = var.encryption.existing_application_data_key_id
  tags                              = local.common_tags
}

# Dedicated access connector for default_storage_firewall_enabled below -
# the azurerm provider requires access_connector_id whenever that firewall
# is enabled, so Databricks' control plane can still reach the
# auto-created DBFS root storage account once it's firewalled. Separate
# from modules/azure/unity-catalog-data's own access connector (that one
# is for the UC managed-storage account, a different storage account
# entirely).
resource "azurerm_databricks_access_connector" "dbfs" {
  name                = "dbac-${var.workspace.name}-dbfs"
  resource_group_name = azurerm_resource_group.this.name
  location            = var.cloud.region

  identity {
    type = "SystemAssigned"
  }

  tags = local.common_tags
}

resource "azurerm_databricks_workspace" "this" {
  name                        = "dbw-${var.workspace.name}"
  resource_group_name         = azurerm_resource_group.this.name
  location                    = var.cloud.region
  sku                         = "premium" # required for Unity Catalog
  managed_resource_group_name = "rg-${var.workspace.name}-managed"

  # Government-readiness hardening (CLAUDE.md §8): default_storage_firewall_enabled
  # has no billing tie, stays unconditional. enhanced_security_compliance's
  # three settings are gated together on compliance_standards being
  # non-empty - Databricks' docs confirm enabling the compliance profile
  # auto-enables enhanced monitoring/automatic cluster update, and all
  # three sit behind the paid "Enhanced Security and Compliance" add-on.
  # Deliberately NOT setting public_network_access_enabled (would make the
  # workspace unreachable - no Azure Private Link built yet) or
  # network_security_group_rules_required (customer-owns-every-NSG-rule is
  # an explicitly deferred follow-up, not changed here).
  default_storage_firewall_enabled = true
  access_connector_id              = azurerm_databricks_access_connector.dbfs.id

  # Classic Private Link (CLAUDE.md §8 milestone 46): the workspace stops
  # using Azure-injected NSG rules; cluster -> control plane and cluster
  # -> DBFS go through the private endpoints below instead. Public network
  # access stays on - front-end Private Link is out of scope. Both left
  # null when off, so existing workspaces see no diff.
  network_security_group_rules_required = var.private_link.enabled ? "NoAzureDatabricksRules" : null
  public_network_access_enabled         = var.private_link.enabled ? true : null

  # Customer-managed keys - managed services is checked by Azure at create
  # time (the kms module's output waits on its grant); managed disks and
  # DBFS root are granted to identities this resource creates, below. Both
  # managed-services and managed-disk CMK are one-way once enabled, per
  # Databricks' docs.
  customer_managed_key_enabled                        = local.workspace_cmk_enabled
  managed_services_cmk_key_vault_key_id               = local.workspace_cmk_enabled ? module.kms[0].managed_services_key.key_id : null
  managed_services_cmk_key_vault_id                   = local.workspace_cmk_enabled ? module.kms[0].managed_services_key.key_vault_id : null
  managed_disk_cmk_key_vault_key_id                   = local.workspace_cmk_enabled ? module.kms[0].workspace_storage_key.key_id : null
  managed_disk_cmk_key_vault_id                       = local.workspace_cmk_enabled ? module.kms[0].workspace_storage_key.key_vault_id : null
  managed_disk_cmk_rotation_to_latest_version_enabled = local.workspace_cmk_enabled ? true : null

  enhanced_security_compliance {
    automatic_cluster_update_enabled      = length(var.compliance_standards) > 0
    compliance_security_profile_enabled   = length(var.compliance_standards) > 0
    compliance_security_profile_standards = var.compliance_standards
    enhanced_security_monitoring_enabled  = length(var.compliance_standards) > 0
  }

  custom_parameters {
    no_public_ip                                         = true
    virtual_network_id                                   = module.network.virtual_network_id
    public_subnet_name                                   = module.network.public_subnet_name
    public_subnet_network_security_group_association_id  = module.network.public_subnet_nsg_association_id
    private_subnet_name                                  = module.network.private_subnet_name
    private_subnet_network_security_group_association_id = module.network.private_subnet_nsg_association_id
  }

  tags = local.common_tags

  depends_on = [
    module.network,
  ]
}

module "private_link" {
  count  = var.private_link.enabled ? 1 : 0
  source = "../workspace-private-link"

  workspace_name                = var.workspace.name
  resource_group_name           = azurerm_resource_group.this.name
  location                      = var.cloud.region
  workspace_resource_id         = azurerm_databricks_workspace.this.id
  managed_resource_group_name   = azurerm_databricks_workspace.this.managed_resource_group_name
  virtual_network_id            = module.network.virtual_network_id
  private_endpoint_subnet_id    = module.network.private_endpoint_subnet_id
  existing_private_dns_zone_ids = var.private_link.existing_private_dns_zone_ids
  tags                          = local.common_tags

  # Its DBFS storage lookup reads the managed resource group, which only
  # exists once the workspace does.
  depends_on = [azurerm_databricks_workspace.this]
}

# Post-create CMK grants: the disk encryption set and the workspace storage
# account each get a system identity only once the workspace exists, so
# they're granted here, after it (Databricks' documented order for both).
resource "azurerm_role_assignment" "managed_disk_cmk" {
  count = local.workspace_cmk_enabled ? 1 : 0

  scope                = module.kms[0].workspace_storage_key.resource_id
  role_definition_name = "Key Vault Crypto Service Encryption User"
  principal_id         = azurerm_databricks_workspace.this.managed_disk_identity[0].principal_id
}

resource "azurerm_role_assignment" "dbfs_cmk" {
  count = local.workspace_cmk_enabled ? 1 : 0

  scope                = module.kms[0].workspace_storage_key.resource_id
  role_definition_name = "Key Vault Crypto Service Encryption User"
  principal_id         = azurerm_databricks_workspace.this.storage_account_identity[0].principal_id
}

resource "time_sleep" "workspace_cmk_rbac_propagation" {
  count = local.workspace_cmk_enabled ? 1 : 0

  create_duration = "60s"

  depends_on = [
    azurerm_role_assignment.managed_disk_cmk,
    azurerm_role_assignment.dbfs_cmk,
  ]
}

resource "azurerm_databricks_workspace_root_dbfs_customer_managed_key" "this" {
  count = local.workspace_cmk_enabled ? 1 : 0

  workspace_id     = azurerm_databricks_workspace.this.id
  key_vault_key_id = module.kms[0].workspace_storage_key.key_id
  key_vault_id     = module.kms[0].workspace_storage_key.key_vault_id

  depends_on = [time_sleep.workspace_cmk_rbac_propagation]
}

# Per-workspace audit-log enablement, pointed at a shared Log Analytics
# destination (CLAUDE.md §10 backlog item #1a / §8 milestone 40). Real
# finding: Azure has no account-level "turn on audit logging for every
# workspace" switch the way AWS's databricks_mws_log_delivery is -
# azurerm_monitor_diagnostic_setting is always scoped to one
# target_resource_id (confirmed from the azurerm provider's own docs),
# so each workspace needs its own copy of this resource, not a single
# account-wide setup. log_analytics_workspace_id is resolved the same
# way as AWS's network_policy_id - at config-generation time in Python
# (resolver/generate_tfvars_azure.py), never via Terraform remote state.
resource "azurerm_monitor_diagnostic_setting" "audit_logs" {
  count = var.log_analytics_workspace_id != null ? 1 : 0

  name                       = "${var.workspace.name}-audit-logs"
  target_resource_id         = azurerm_databricks_workspace.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  dynamic "enabled_log" {
    for_each = var.audit_log_categories
    content {
      category = enabled_log.value
    }
  }
}
