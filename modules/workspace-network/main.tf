data "aws_vpc" "workspace" {
  id = var.vpc_id
}

locals {
  common_tags = merge(
    var.tags,
    {
      ManagedBy = "terraform"
      Component = "databricks-workspace-network"
      Workspace = var.workspace_name
    }
  )
}

resource "aws_subnet" "private" {
  count = length(var.private_subnets)

  vpc_id = data.aws_vpc.workspace.id

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

resource "aws_route_table_association" "private" {
  count = length(var.private_subnets)

  subnet_id = aws_subnet.private[count.index].id

  route_table_id = var.route_table_ids[count.index]
}

resource "aws_security_group" "workspace" {
  name        = "${var.workspace_name}-databricks"
  description = "Security group for Databricks workspace ${var.workspace_name}"
  vpc_id      = data.aws_vpc.workspace.id

  tags = merge(
    local.common_tags,
    {
      Name = "${var.workspace_name}-databricks"
    }
  )
}

resource "aws_vpc_security_group_egress_rule" "workspace" {
  security_group_id = aws_security_group.workspace.id

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"

  description = "Allow outbound workspace traffic"
}