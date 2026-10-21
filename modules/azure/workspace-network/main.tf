# Three shapes, selected by which existing_* inputs are set (same
# existing-or-create variable pattern as modules/aws/workspace-network -
# CLAUDE.md ยง9):
#
# 1. isolated (existing_vnet_id null) - the original create-only path,
#    validated against a real Azure subscription (CLAUDE.md ยง8 milestone
#    35): a brand-new VNet with two subnets delegated to
#    Microsoft.Databricks/workspaces (Databricks' own "public"/"private"
#    naming - no public IP is actually assigned to anything, see
#    azurerm_databricks_workspace's no_public_ip = true in
#    modules/azure/workspace-deployment) plus a baseline NSG (default
#    rules only).
# 2. custom, create subnets (existing_vnet_id set, no existing subnet ids)
#    - the client hands over a VNet; this module creates the two
#    delegated subnets + NSG inside it. Subnets have to live in the VNet's
#    own resource group (parsed from its id), not the workspace's; the NSG
#    stays in the workspace's resource group (an NSG only has to share
#    the subnet's region/subscription, not its resource group).
# 3. custom, adopt subnets (existing_vnet_id + both existing subnet ids
#    set) - nothing is created here at all. Adopted subnets must already
#    be delegated to Microsoft.Databricks/workspaces and have an NSG
#    associated (Azure's workspace-creation API requires both); the NSG
#    association is checked at plan time below, the delegation isn't (the
#    azurerm_subnet data source doesn't expose it) - Azure rejects a
#    non-delegated subnet at workspace creation with a clear error.
#
# The baseline NSG's default rules (no extra Secure-Cluster-Connectivity
# rules) were confirmed sufficient for real cluster traffic by a second
# real-subscription spike (CLAUDE.md Sec8, the cluster/NSG milestone): a
# single-node cluster reached RUNNING and ran a real notebook job.
# Internet egress also worked with no NAT/firewall of any kind - Azure's
# default-outbound-internet-access for VMs in a VNet subnet covered it.
# Revisit only if Azure ever changes that default, or a client's own
# Azure Policy disables it tenant-wide (more likely in shape 2/3, where
# the VNet belongs to the client).

locals {
  create_vnet    = var.existing_vnet_id == null
  create_subnets = var.existing_public_subnet_id == null

  # Azure VNet id shape: /subscriptions/<sub>/resourceGroups/<rg>/providers/
  # Microsoft.Network/virtualNetworks/<name> - validated in variables.tf.
  existing_vnet_parts = local.create_vnet ? [] : split("/", var.existing_vnet_id)

  vnet_resource_group_name = local.create_vnet ? var.resource_group_name : local.existing_vnet_parts[4]
  vnet_name                = local.create_vnet ? azurerm_virtual_network.this[0].name : local.existing_vnet_parts[8]
  vnet_id                  = local.create_vnet ? azurerm_virtual_network.this[0].id : data.azurerm_virtual_network.existing[0].id
}

resource "azurerm_virtual_network" "this" {
  count = local.create_vnet ? 1 : 0

  name                = "vnet-${var.workspace_name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  address_space       = [var.vpc_cidr]

  tags = var.tags
}

# Plan-time existence check for a client-provided VNet (fails the plan,
# rather than the apply, on a wrong id).
data "azurerm_virtual_network" "existing" {
  count = local.create_vnet ? 0 : 1

  name                = local.existing_vnet_parts[8]
  resource_group_name = local.existing_vnet_parts[4]
}

resource "azurerm_network_security_group" "this" {
  count = local.create_subnets ? 1 : 0

  name                = "nsg-${var.workspace_name}"
  resource_group_name = var.resource_group_name
  location            = var.location

  tags = var.tags
}

resource "azurerm_subnet" "public" {
  count = local.create_subnets ? 1 : 0

  # Prefixed with the workspace name only when sharing a client VNet - a
  # VNet can hold several workspaces' subnet pairs, and subnet names are
  # unique per VNet. Unchanged ("public-subnet") for isolated, so already-
  # applied isolated workspaces don't see a forced replacement.
  name                 = local.create_vnet ? "public-subnet" : "${var.workspace_name}-public"
  resource_group_name  = local.vnet_resource_group_name
  virtual_network_name = local.vnet_name
  address_prefixes     = [var.public_subnet_cidr]

  delegation {
    name = "databricks-delegation"

    service_delegation {
      name = "Microsoft.Databricks/workspaces"
      # All three listed, not just join - Azure adds the two
      # prepare/unprepareNetworkPolicies actions itself, so declaring only
      # join shows as permanent drift on every plan (found on the first
      # real custom-strategy apply, CLAUDE.md ง8 milestone 41).
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
        "Microsoft.Network/virtualNetworks/subnets/prepareNetworkPolicies/action",
        "Microsoft.Network/virtualNetworks/subnets/unprepareNetworkPolicies/action",
      ]
    }
  }
}

resource "azurerm_subnet" "private" {
  count = local.create_subnets ? 1 : 0

  name                 = local.create_vnet ? "private-subnet" : "${var.workspace_name}-private"
  resource_group_name  = local.vnet_resource_group_name
  virtual_network_name = local.vnet_name
  address_prefixes     = [var.private_subnet_cidr]

  delegation {
    name = "databricks-delegation"

    service_delegation {
      name = "Microsoft.Databricks/workspaces"
      # All three listed, not just join - Azure adds the two
      # prepare/unprepareNetworkPolicies actions itself, so declaring only
      # join shows as permanent drift on every plan (found on the first
      # real custom-strategy apply, CLAUDE.md ง8 milestone 41).
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
        "Microsoft.Network/virtualNetworks/subnets/prepareNetworkPolicies/action",
        "Microsoft.Network/virtualNetworks/subnets/unprepareNetworkPolicies/action",
      ]
    }
  }
}

resource "azurerm_subnet_network_security_group_association" "public" {
  count = local.create_subnets ? 1 : 0

  subnet_id                 = azurerm_subnet.public[0].id
  network_security_group_id = azurerm_network_security_group.this[0].id
}

resource "azurerm_subnet_network_security_group_association" "private" {
  count = local.create_subnets ? 1 : 0

  subnet_id                 = azurerm_subnet.private[0].id
  network_security_group_id = azurerm_network_security_group.this[0].id
}

data "azurerm_subnet" "existing_public" {
  count = local.create_subnets ? 0 : 1

  name = element(split("/", var.existing_public_subnet_id), 10)
  # Parsed straight from existing_vnet_id, not via local.vnet_name/
  # vnet_resource_group_name - those also reference the workspace's own
  # (not-yet-created) resource group, which would defer this read (and its
  # NSG postcondition) from plan time to apply time.
  virtual_network_name = local.existing_vnet_parts[8]
  resource_group_name  = local.existing_vnet_parts[4]

  lifecycle {
    postcondition {
      condition     = try(length(self.network_security_group_id), 0) > 0
      error_message = "Adopted public subnet ${var.existing_public_subnet_id} has no NSG associated - Azure Databricks VNet injection requires one on both subnets."
    }
  }
}

data "azurerm_subnet" "existing_private" {
  count = local.create_subnets ? 0 : 1

  name = element(split("/", var.existing_private_subnet_id), 10)
  # Parsed straight from existing_vnet_id, not via local.vnet_name/
  # vnet_resource_group_name - those also reference the workspace's own
  # (not-yet-created) resource group, which would defer this read (and its
  # NSG postcondition) from plan time to apply time.
  virtual_network_name = local.existing_vnet_parts[8]
  resource_group_name  = local.existing_vnet_parts[4]

  lifecycle {
    postcondition {
      condition     = try(length(self.network_security_group_id), 0) > 0
      error_message = "Adopted private subnet ${var.existing_private_subnet_id} has no NSG associated - Azure Databricks VNet injection requires one on both subnets."
    }
  }
}

# Pre-existing isolated workspaces' state addresses gained a [0] index when
# count was added above.
moved {
  from = azurerm_virtual_network.this
  to   = azurerm_virtual_network.this[0]
}

moved {
  from = azurerm_network_security_group.this
  to   = azurerm_network_security_group.this[0]
}

moved {
  from = azurerm_subnet.public
  to   = azurerm_subnet.public[0]
}

moved {
  from = azurerm_subnet.private
  to   = azurerm_subnet.private[0]
}

moved {
  from = azurerm_subnet_network_security_group_association.public
  to   = azurerm_subnet_network_security_group_association.public[0]
}

moved {
  from = azurerm_subnet_network_security_group_association.private
  to   = azurerm_subnet_network_security_group_association.private[0]
}
