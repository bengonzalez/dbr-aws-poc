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

  workspace_name      = var.workspace.name
  location            = var.cloud.region
  resource_group_name = azurerm_resource_group.this.name
  vpc_cidr            = var.network.vpc_cidr
  public_subnet_cidr  = var.network.public_subnet_cidr
  private_subnet_cidr = var.network.private_subnet_cidr
  tags                = local.common_tags
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
