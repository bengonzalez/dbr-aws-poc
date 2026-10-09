locals {
  create_vpc            = var.existing_vpc_id == null
  create_routing        = var.existing_route_table_ids == null
  create_security_group = var.existing_security_group_id == null

  common_tags = merge(
    var.tags,
    {
      ManagedBy = "terraform"
      Component = "databricks-workspace-network"
      Workspace = var.workspace_name
    }
  )

  vpc_id = local.create_vpc ? aws_vpc.this[0].id : data.aws_vpc.existing[0].id

  route_table_ids = (
    local.create_routing ?
    aws_route_table.private[*].id : var.existing_route_table_ids
  )
}

# ---------------------------------------------------------------------------
# VPC — reuse an existing one, or create a new one (isolated strategy).
# ---------------------------------------------------------------------------

data "aws_vpc" "existing" {
  count = local.create_vpc ? 0 : 1
  id    = var.existing_vpc_id
}

resource "aws_vpc" "this" {
  count = local.create_vpc ? 1 : 0

  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    Name = "${var.workspace_name}-vpc"
  })
}

# ---------------------------------------------------------------------------
# Subnets — always created by this module, inside whichever VPC is in use.
# ---------------------------------------------------------------------------

resource "aws_subnet" "private" {
  count = length(var.private_subnets)

  vpc_id = local.vpc_id

  cidr_block        = var.private_subnets[count.index].cidr
  availability_zone = var.private_subnets[count.index].availability_zone

  map_public_ip_on_launch = false

  tags = merge(
    local.common_tags,
    {
      Name = "${var.workspace_name}-private-${count.index + 1}"
      Tier = "private"
    }
  )
}

# ---------------------------------------------------------------------------
# Routing — reuse existing route tables, or create new ones. Created route
# tables carry only the VPC's implicit local route (no NAT/IGW), matching
# the private-only topology already proven for this platform.
# ---------------------------------------------------------------------------

resource "aws_route_table" "private" {
  count = local.create_routing ? length(var.private_subnets) : 0

  vpc_id = local.vpc_id

  tags = merge(local.common_tags, {
    Name = "${var.workspace_name}-private-${count.index + 1}"
  })
}

resource "aws_route_table_association" "private" {
  count = length(var.private_subnets)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = local.route_table_ids[count.index]
}

# ---------------------------------------------------------------------------
# Security group — reuse an existing one, or create a new one.
# ---------------------------------------------------------------------------

data "aws_security_group" "existing" {
  count = local.create_security_group ? 0 : 1
  id    = var.existing_security_group_id
}

resource "aws_security_group" "workspace" {
  count = local.create_security_group ? 1 : 0

  name        = "${var.workspace_name}-databricks"
  description = "Security group for Databricks workspace ${var.workspace_name}"
  vpc_id      = local.vpc_id

  tags = merge(
    local.common_tags,
    {
      Name = "${var.workspace_name}-databricks"
    }
  )
}

resource "aws_vpc_security_group_egress_rule" "workspace" {
  count = local.create_security_group ? 1 : 0

  security_group_id = aws_security_group.workspace[0].id

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"

  description = "Allow outbound workspace traffic"
}

# Preserve state for workspaces applied before the security group gained a
# count (to support existing_security_group_id).
moved {
  from = aws_security_group.workspace
  to   = aws_security_group.workspace[0]
}

moved {
  from = aws_vpc_security_group_egress_rule.workspace
  to   = aws_vpc_security_group_egress_rule.workspace[0]
}
