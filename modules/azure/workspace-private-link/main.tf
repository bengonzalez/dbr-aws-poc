# Classic (back-end) Azure Private Link for one workspace (CLAUDE.md §8
# milestone 46) - Databricks' "classic compute plane private connectivity"
# pattern, from Microsoft's own docs:
#
#   - a databricks_ui_api private endpoint to the workspace, so clusters
#     reach the control plane (REST + secure cluster connectivity relay)
#     over the Microsoft backbone, not the internet;
#   - dfs + blob private endpoints to the workspace's DBFS storage
#     account. The storage firewall (default_storage_firewall_enabled,
#     milestone 38) requires them once the workspace stops using
#     Azure-injected NSG rules (NoAzureDatabricksRules, set by the caller);
#   - the three privatelink DNS zones, linked to the workspace VNet so
#     cluster nodes resolve those names to the private IPs - or, when the
#     client brings hub zones (existing_private_dns_zone_ids), nothing is
#     created or linked and the endpoints' records go into those zones.
#
# Front-end (user) Private Link is deliberately out of scope: the
# workspace keeps public network access, so users and this factory's own
# tooling still reach the UI/API. Closing that needs a transit VNet and a
# network path in (VPN/jump host) first.

locals {
  zone_names = {
    databricks = "privatelink.azuredatabricks.net"
    dfs        = "privatelink.dfs.core.windows.net"
    blob       = "privatelink.blob.core.windows.net"
  }

  create_zones = var.existing_private_dns_zone_ids == null

  zone_ids = local.create_zones ? {
    for key, zone in azurerm_private_dns_zone.this : key => zone.id
  } : var.existing_private_dns_zone_ids

  # The DBFS storage account lives in the workspace's Databricks-managed
  # resource group under a generated name (dbstorage...), so it's found by
  # type rather than named - it's the only storage account Databricks puts
  # there.
  dbfs_storage_account_ids = [
    for resource in data.azurerm_resources.dbfs_storage.resources : resource.id
    if startswith(resource.name, "dbstorage")
  ]
}

data "azurerm_resources" "dbfs_storage" {
  resource_group_name = var.managed_resource_group_name
  type                = "Microsoft.Storage/storageAccounts"
}

resource "azurerm_private_dns_zone" "this" {
  for_each = local.create_zones ? local.zone_names : {}

  name                = each.value
  resource_group_name = var.resource_group_name

  tags = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  for_each = local.create_zones ? local.zone_names : {}

  name                  = "${var.workspace_name}-${each.key}"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.this[each.key].name
  virtual_network_id    = var.virtual_network_id

  tags = var.tags
}

resource "azurerm_private_endpoint" "databricks_ui_api" {
  name                = "pe-${var.workspace_name}-ui-api"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoint_subnet_id

  private_service_connection {
    name                           = "${var.workspace_name}-ui-api"
    private_connection_resource_id = var.workspace_resource_id
    subresource_names              = ["databricks_ui_api"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "databricks"
    private_dns_zone_ids = [local.zone_ids["databricks"]]
  }

  tags = var.tags

  depends_on = [azurerm_private_dns_zone_virtual_network_link.this]
}

resource "azurerm_private_endpoint" "dbfs" {
  for_each = toset(["dfs", "blob"])

  name                = "pe-${var.workspace_name}-dbfs-${each.key}"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoint_subnet_id

  private_service_connection {
    name                           = "${var.workspace_name}-dbfs-${each.key}"
    private_connection_resource_id = one(local.dbfs_storage_account_ids)
    subresource_names              = [each.key]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = each.key
    private_dns_zone_ids = [local.zone_ids[each.key]]
  }

  tags = var.tags

  depends_on = [azurerm_private_dns_zone_virtual_network_link.this]
}
