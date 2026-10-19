locals {
  create_vpc            = var.existing_vpc_id == null
  create_subnets        = var.existing_subnet_ids == null
  create_routing        = var.existing_route_table_ids == null
  create_security_group = var.existing_security_group_id == null

  # NAT only applies when this module is creating the VPC itself - see
  # variables.tf. The private-route half additionally needs this module
  # to own routing too (can't add a route to a foreign route table).
  build_nat         = var.nat_enabled && local.create_vpc
  build_nat_routing = local.build_nat && local.create_routing

  common_tags = merge(
    var.tags,
    {
      ManagedBy = "terraform"
      Component = "databricks-workspace-network"
      Workspace = var.workspace_name
    }
  )

  vpc_id = local.create_vpc ? aws_vpc.this[0].id : data.aws_vpc.existing[0].id

  # Adopted subnet ids are trusted as given, same as existing_route_table_ids
  # below - no data-source lookup, so a typo'd id surfaces as a Databricks/AWS
  # apply-time error rather than a plan-time one. Known limitation: because
  # their real CIDRs are never looked up, adopted subnets are invisible to
  # resolver/check_cidr_allocations.py's collision checker (CLAUDE.md §8
  # milestone 33) - a sibling workspace auto-allocating into the same VPC
  # could theoretically pick a range that overlaps one of these.
  subnet_ids   = local.create_subnets ? aws_subnet.private[*].id : var.existing_subnet_ids
  subnet_count = local.create_subnets ? length(var.private_subnets) : length(var.existing_subnet_ids)

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
# Subnets — reuse existing ones (existing_subnet_ids), or create new ones
# inside whichever VPC is in use.
# ---------------------------------------------------------------------------

resource "aws_subnet" "private" {
  count = local.create_subnets ? length(var.private_subnets) : 0

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
  count = local.create_routing ? local.subnet_count : 0

  vpc_id = local.vpc_id

  tags = merge(local.common_tags, {
    Name = "${var.workspace_name}-private-${count.index + 1}"
  })
}

resource "aws_route_table_association" "private" {
  count = local.subnet_count

  subnet_id      = local.subnet_ids[count.index]
  route_table_id = local.route_table_ids[count.index]
}

# ---------------------------------------------------------------------------
# NAT Gateway fallback — a single NAT Gateway (not multi-AZ HA; this is a
# connectivity fallback for accounts without Databricks PrivateLink, not a
# production HA redesign), shared by both private route tables. Only built
# when this module owns the VPC (see locals.build_nat above).
# ---------------------------------------------------------------------------

resource "aws_internet_gateway" "this" {
  count = local.build_nat ? 1 : 0

  vpc_id = local.vpc_id

  tags = merge(local.common_tags, {
    Name = "${var.workspace_name}-igw"
  })
}

resource "aws_subnet" "nat" {
  count = local.build_nat ? 1 : 0

  vpc_id = local.vpc_id

  cidr_block        = var.nat_subnet_cidr
  availability_zone = var.private_subnets[0].availability_zone

  map_public_ip_on_launch = false

  tags = merge(local.common_tags, {
    Name = "${var.workspace_name}-nat"
    Tier = "public"
  })
}

resource "aws_eip" "nat" {
  count = local.build_nat ? 1 : 0

  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "${var.workspace_name}-nat"
  })

  depends_on = [
    aws_internet_gateway.this
  ]
}

resource "aws_nat_gateway" "this" {
  count = local.build_nat ? 1 : 0

  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.nat[0].id

  tags = merge(local.common_tags, {
    Name = "${var.workspace_name}-nat"
  })

  depends_on = [
    aws_internet_gateway.this
  ]
}

resource "aws_route_table" "public" {
  count = local.build_nat ? 1 : 0

  vpc_id = local.vpc_id

  tags = merge(local.common_tags, {
    Name = "${var.workspace_name}-public"
  })
}

resource "aws_route" "public_igw" {
  count = local.build_nat ? 1 : 0

  route_table_id         = aws_route_table.public[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this[0].id
}

resource "aws_route_table_association" "nat" {
  count = local.build_nat ? 1 : 0

  subnet_id      = aws_subnet.nat[0].id
  route_table_id = aws_route_table.public[0].id
}

# Default route for the private subnets - only when this module also
# created the route tables they're associated with (can't modify a
# foreign/existing route table).
resource "aws_route" "private_nat" {
  count = local.build_nat_routing ? length(var.private_subnets) : 0

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[0].id
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
