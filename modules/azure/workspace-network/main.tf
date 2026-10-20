# Create-only path - validated directly against a real Azure subscription
# (throwaway spike, see the Azure milestone's CLAUDE.md entry): a VNet with
# two subnets delegated to Microsoft.Databricks/workspaces (Databricks'
# own "public"/"private" naming - no public IP is actually assigned to
# anything, see azurerm_databricks_workspace's no_public_ip = true in
# modules/azure-workspace-deployment) plus a baseline NSG (default rules
# only). No existing-VNet-reuse variables yet - deferred, same as how
# AWS's own "custom" strategy was built on top of a working "isolated"
# baseline across several later milestones, not all at once.
#
# Known, documented gap (not silently "fixed" here): whether the baseline
# NSG's default rules are actually sufficient for real cluster traffic -
# Microsoft's docs recommend additional Secure-Cluster-Connectivity rules -
# was never verified by the spike (no cluster was started). Revisit before
# relying on this for anything beyond workspace creation.

resource "azurerm_virtual_network" "this" {
  name                = "vnet-${var.workspace_name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  address_space       = [var.vpc_cidr]

  tags = var.tags
}

resource "azurerm_network_security_group" "this" {
  name                = "nsg-${var.workspace_name}"
  resource_group_name = var.resource_group_name
  location            = var.location

  tags = var.tags
}

resource "azurerm_subnet" "public" {
  name                 = "public-subnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.public_subnet_cidr]

  delegation {
    name = "databricks-delegation"

    service_delegation {
      name    = "Microsoft.Databricks/workspaces"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "private" {
  name                 = "private-subnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.private_subnet_cidr]

  delegation {
    name = "databricks-delegation"

    service_delegation {
      name    = "Microsoft.Databricks/workspaces"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet_network_security_group_association" "public" {
  subnet_id                 = azurerm_subnet.public.id
  network_security_group_id = azurerm_network_security_group.this.id
}

resource "azurerm_subnet_network_security_group_association" "private" {
  subnet_id                 = azurerm_subnet.private.id
  network_security_group_id = azurerm_network_security_group.this.id
}
