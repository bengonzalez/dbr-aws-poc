# A client-built VPC of exactly the shape in client-vpc-handoff-template.yaml
# (the Notion "VPC Created by client" table), for testing and demos of
# CLAUDE.md §10 item #15. Stands in for the client: the workspace factory
# never manages anything here.

data "aws_caller_identity" "current" {}

locals {
  name = var.workspace_name

  # /27 -> two /28 edge subnets.
  edge_cidrs = [for i in range(2) : cidrsubnet(var.primary_cidr, 1, i)]

  # /19 -> two /21 compute subnets (100.64.0.0, 100.64.8.0), then two /26
  # backend subnets from the third /21 (100.64.16.0, 100.64.16.64).
  compute_cidrs = [for i in range(2) : cidrsubnet(var.secondary_cidr, 2, i)]
  backend_cidrs = [for i in range(2) : cidrsubnet(cidrsubnet(var.secondary_cidr, 2, 2), 5, i)]
}

# ---------------------------------------------------------------------------
# VPC + secondary CIDR
# ---------------------------------------------------------------------------

resource "aws_vpc" "this" {
  cidr_block           = var.primary_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${local.name}-vpc" }
}

resource "aws_vpc_ipv4_cidr_block_association" "secondary" {
  vpc_id     = aws_vpc.this.id
  cidr_block = var.secondary_cidr
}

# ---------------------------------------------------------------------------
# Subnets (per AZ: edge /28, compute /21, backend /26)
# ---------------------------------------------------------------------------

resource "aws_subnet" "edge" {
  count = 2

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.edge_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = { Name = "${local.name}-edge-${var.availability_zones[count.index]}" }
}

resource "aws_subnet" "compute" {
  count = 2

  # Through the association, so these wait for the secondary CIDR.
  vpc_id            = aws_vpc_ipv4_cidr_block_association.secondary.vpc_id
  cidr_block        = local.compute_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = { Name = "${local.name}-compute-${var.availability_zones[count.index]}" }
}

resource "aws_subnet" "backend" {
  count = 2

  vpc_id            = aws_vpc_ipv4_cidr_block_association.secondary.vpc_id
  cidr_block        = local.backend_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = { Name = "${local.name}-backend-${var.availability_zones[count.index]}" }
}

# ---------------------------------------------------------------------------
# Private NAT gateways (one per edge subnet, no EIP, no IGW)
# ---------------------------------------------------------------------------

resource "aws_nat_gateway" "private" {
  count = 2

  connectivity_type = "private"
  subnet_id         = aws_subnet.edge[count.index].id

  tags = { Name = "${local.name}-nat-${var.availability_zones[count.index]}" }
}

# ---------------------------------------------------------------------------
# Optional Transit Gateway
# ---------------------------------------------------------------------------

resource "aws_ec2_transit_gateway" "this" {
  count = var.create_transit_gateway ? 1 : 0

  description = "${local.name} fixture TGW"

  tags = { Name = "${local.name}-tgw" }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  count = var.create_transit_gateway ? 1 : 0

  transit_gateway_id = aws_ec2_transit_gateway.this[0].id
  vpc_id             = aws_vpc.this.id
  subnet_ids         = aws_subnet.edge[*].id

  transit_gateway_default_route_table_propagation = false

  tags = { Name = "${local.name}-tgw-attachment" }
}

resource "aws_ec2_transit_gateway_route" "primary" {
  count = var.create_transit_gateway ? 1 : 0

  destination_cidr_block         = var.primary_cidr
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[0].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway.this[0].association_default_route_table_id
}

# ---------------------------------------------------------------------------
# Route tables: compute x2, edge, backend
# ---------------------------------------------------------------------------

resource "aws_route_table" "compute" {
  count = 2

  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.private[count.index].id
  }

  tags = { Name = "${local.name}-compute-${var.availability_zones[count.index]}" }
}

resource "aws_route_table" "edge" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "${local.name}-edge" }
}

resource "aws_route" "edge_default" {
  count = var.create_transit_gateway ? 1 : 0

  route_table_id         = aws_route_table.edge.id
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = aws_ec2_transit_gateway.this[0].id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

resource "aws_route_table" "backend" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "${local.name}-backend" }
}

resource "aws_route_table_association" "compute" {
  count = 2

  subnet_id      = aws_subnet.compute[count.index].id
  route_table_id = aws_route_table.compute[count.index].id
}

resource "aws_route_table_association" "edge" {
  count = 2

  subnet_id      = aws_subnet.edge[count.index].id
  route_table_id = aws_route_table.edge.id
}

resource "aws_route_table_association" "backend" {
  count = 2

  subnet_id      = aws_subnet.backend[count.index].id
  route_table_id = aws_route_table.backend.id
}

# ---------------------------------------------------------------------------
# S3 gateway endpoint on both compute route tables (default full policy)
# ---------------------------------------------------------------------------

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.compute[*].id

  tags = { Name = "${local.name}-s3" }
}

# ---------------------------------------------------------------------------
# The filled handoff, as the client would return it
# ---------------------------------------------------------------------------

locals {
  handoff = {
    handoff_version = 1

    workspace = {
      name        = var.workspace_name
      environment = var.environment
      application = var.workspace_name
    }

    contacts = {
      network_owner_name  = "Client VPC fixture"
      network_owner_email = "fixture@example.com"
    }

    aws = {
      account_id = data.aws_caller_identity.current.account_id
      region     = var.region
    }

    databricks = {
      account_id      = var.databricks_account_id
      enterprise_tier = var.databricks_enterprise_tier
    }

    vpc = {
      id                    = aws_vpc.this.id
      primary_cidr          = var.primary_cidr
      secondary_cidr        = var.secondary_cidr
      dns_support_enabled   = true
      dns_hostnames_enabled = true
    }

    availability_zones = [
      for i in range(2) : {
        name = var.availability_zones[i]
        edge_subnet = {
          id   = aws_subnet.edge[i].id
          cidr = aws_subnet.edge[i].cidr_block
        }
        compute_subnet = {
          id             = aws_subnet.compute[i].id
          cidr           = aws_subnet.compute[i].cidr_block
          route_table_id = aws_route_table.compute[i].id
        }
        backend_subnet = {
          id   = aws_subnet.backend[i].id
          cidr = aws_subnet.backend[i].cidr_block
        }
        private_nat_gateway_id = aws_nat_gateway.private[i].id
      }
    ]

    route_tables = {
      edge_route_table_id    = aws_route_table.edge.id
      backend_route_table_id = aws_route_table.backend.id
    }

    transit_gateway = {
      id                                = var.create_transit_gateway ? aws_ec2_transit_gateway.this[0].id : ""
      attachment_id                     = var.create_transit_gateway ? aws_ec2_transit_gateway_vpc_attachment.this[0].id : ""
      route_tables_in_this_account      = true
      route_table_ids_with_static_route = var.create_transit_gateway ? [aws_ec2_transit_gateway.this[0].association_default_route_table_id] : []
      static_routes_in_place            = var.create_transit_gateway
    }

    vpc_endpoints = {
      s3_gateway_endpoint_id           = aws_vpc_endpoint.s3.id
      sts_interface_endpoint_id        = ""
      kms_interface_endpoint_id        = ""
      databricks_rest_api_endpoint_id  = ""
      databricks_scc_relay_endpoint_id = ""
    }

    egress = {
      # No hub behind the TGW (or no TGW at all): nothing leaves the VPC.
      databricks_control_plane_allowed = "false"
      inspection_device                = ""
    }

    dns = {
      amazon_provided_dns = true
    }

    notes = "Generated by test-fixtures/aws/client-vpc - a stand-in for a client-built VPC, not a real handoff."
  }
}

resource "local_file" "handoff" {
  filename = "${path.module}/${var.handoff_dir}/${var.environment}/${var.workspace_name}.yaml"
  content  = "# Generated by test-fixtures/aws/client-vpc. Do not edit; re-run terraform apply.\n${yamlencode(local.handoff)}"
}
