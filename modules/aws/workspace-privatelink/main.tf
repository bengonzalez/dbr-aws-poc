locals {
  # Databricks' published AWS PrivateLink VPC endpoint service names for the
  # standard (commercial, non-GovCloud) us-east-1 shard, verified against
  # databricks/terraform-databricks-sra's aws/tf/variables.tf. This factory
  # targets AWS commercial/us-east-1 only (see CLAUDE.md), so these are kept
  # as plain constants rather than a per-region map.
  general_access_service_name = "com.amazonaws.vpce.us-east-1.vpce-svc-09143d1e626de2f04"
  scc_relay_service_name      = "com.amazonaws.vpce.us-east-1.vpce-svc-00018a8c3ff62ffdf"

  common_tags = merge(
    var.tags,
    {
      ManagedBy = "terraform"
      Component = "databricks-workspace-privatelink"
      Workspace = var.workspace_name
    }
  )
}

# ---------------------------------------------------------------------------
# Security group for the PrivateLink interface endpoints. Ingress is scoped
# to the workspace compute security group (not a CIDR block), matching the
# SRA reference architecture's port list for control-plane connectivity.
# ---------------------------------------------------------------------------

resource "aws_security_group" "privatelink" {
  name        = "${var.workspace_name}-privatelink"
  description = "Security group for Databricks PrivateLink endpoints (workspace ${var.workspace_name})"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, {
    Name = "${var.workspace_name}-privatelink"
  })
}

resource "aws_vpc_security_group_ingress_rule" "rest_api" {
  security_group_id = aws_security_group.privatelink.id

  description                  = "Databricks REST API"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = var.workspace_security_group_id
}

resource "aws_vpc_security_group_ingress_rule" "scc_compliance_profile" {
  security_group_id = aws_security_group.privatelink.id

  description                  = "Secure Cluster Connectivity - Compliance Security Profile"
  ip_protocol                  = "tcp"
  from_port                    = 2443
  to_port                      = 2443
  referenced_security_group_id = var.workspace_security_group_id
}

resource "aws_vpc_security_group_ingress_rule" "lakebase_postgres" {
  security_group_id = aws_security_group.privatelink.id

  description                  = "Lakebase PostgreSQL"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = var.workspace_security_group_id
}

resource "aws_vpc_security_group_ingress_rule" "control_plane_internal" {
  security_group_id = aws_security_group.privatelink.id

  description                  = "Compute plane to control plane internal calls"
  ip_protocol                  = "tcp"
  from_port                    = 8443
  to_port                      = 8443
  referenced_security_group_id = var.workspace_security_group_id
}

resource "aws_vpc_security_group_ingress_rule" "uc_logging_lineage" {
  security_group_id = aws_security_group.privatelink.id

  description                  = "Unity Catalog logging and lineage data streaming"
  ip_protocol                  = "tcp"
  from_port                    = 8444
  to_port                      = 8444
  referenced_security_group_id = var.workspace_security_group_id
}

resource "aws_vpc_security_group_ingress_rule" "future_extendability" {
  security_group_id = aws_security_group.privatelink.id

  description                  = "Future extendability"
  ip_protocol                  = "tcp"
  from_port                    = 8445
  to_port                      = 8451
  referenced_security_group_id = var.workspace_security_group_id
}

# ---------------------------------------------------------------------------
# AWS-side PrivateLink interface endpoints.
# ---------------------------------------------------------------------------

resource "aws_vpc_endpoint" "general_access" {
  vpc_id = var.vpc_id

  service_name      = local.general_access_service_name
  vpc_endpoint_type = "Interface"
  subnet_ids        = var.private_subnet_ids

  security_group_ids = [
    aws_security_group.privatelink.id
  ]

  private_dns_enabled = true

  tags = merge(local.common_tags, {
    Name = "${var.workspace_name}-databricks-general-access"
  })
}

resource "aws_vpc_endpoint" "scc_relay" {
  vpc_id = var.vpc_id

  service_name      = local.scc_relay_service_name
  vpc_endpoint_type = "Interface"
  subnet_ids        = var.private_subnet_ids

  security_group_ids = [
    aws_security_group.privatelink.id
  ]

  private_dns_enabled = true

  tags = merge(local.common_tags, {
    Name = "${var.workspace_name}-databricks-dataplane-relay"
  })
}

# ---------------------------------------------------------------------------
# Register the endpoints with the Databricks account, and create the
# private access settings that disable public access to the workspace.
# ---------------------------------------------------------------------------

resource "databricks_mws_vpc_endpoint" "general_access" {
  provider = databricks.mws

  account_id          = var.databricks_account_id
  aws_vpc_endpoint_id = aws_vpc_endpoint.general_access.id
  vpc_endpoint_name   = "${var.workspace_name}-general-access"
  region              = var.aws_region
}

resource "databricks_mws_vpc_endpoint" "scc_relay" {
  provider = databricks.mws

  account_id          = var.databricks_account_id
  aws_vpc_endpoint_id = aws_vpc_endpoint.scc_relay.id
  vpc_endpoint_name   = "${var.workspace_name}-dataplane-relay"
  region              = var.aws_region
}

resource "databricks_mws_private_access_settings" "this" {
  provider = databricks.mws

  # account_id is set on the databricks.mws provider block; passing it here
  # too is deprecated as of recent provider versions.
  private_access_settings_name = "${var.workspace_name}-private-access"
  region                       = var.aws_region
  public_access_enabled        = false
}
