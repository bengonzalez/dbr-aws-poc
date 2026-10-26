locals {
  common_tags = merge(
    var.tags,
    {
      ManagedBy = "terraform"
      Component = "databricks-workspace-endpoints"
      Workspace = var.workspace_name
    }
  )

  # Each endpoint is either the client's (existing_*_endpoint_id) or
  # created here (CLAUDE.md §10 item #15).
  create_s3  = var.existing_s3_gateway_endpoint_id == null
  create_sts = var.existing_sts_endpoint_id == null
  create_kms = var.enable_kms_endpoint && var.existing_kms_endpoint_id == null

  create_interface_sg = local.create_sts || local.create_kms

  # Interface endpoints go in dedicated endpoint subnets when given (a
  # client's backend tier), else alongside compute.
  interface_subnet_ids = coalesce(var.interface_endpoint_subnet_ids, var.private_subnet_ids)
}

# ---------------------------------------------------------------------------
# S3 gateway endpoint — DBFS/root bucket access with no NAT/IGW in the VPC.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "s3_endpoint" {
  count = local.create_s3 ? 1 : 0

  statement {
    effect = "Allow"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:ListBucket"]
    resources = var.s3_bucket_arns
  }

  statement {
    effect = "Allow"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]

    resources = [for arn in var.s3_bucket_arns : "${arn}/*"]
  }
}

resource "aws_vpc_endpoint" "s3" {
  count = local.create_s3 ? 1 : 0

  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = var.route_table_ids
  policy            = data.aws_iam_policy_document.s3_endpoint[0].json

  tags = merge(local.common_tags, {
    Name = "${var.workspace_name}-s3-endpoint"
  })
}

# A client's S3 gateway endpoint must already route every compute subnet;
# its policy is the client's and has to allow the workspace buckets.
data "aws_vpc_endpoint" "existing_s3" {
  count = local.create_s3 ? 0 : 1
  id    = var.existing_s3_gateway_endpoint_id

  lifecycle {
    postcondition {
      condition     = self.vpc_id == var.vpc_id && length(setsubtract(var.route_table_ids, self.route_table_ids)) == 0
      error_message = "S3 gateway endpoint ${var.existing_s3_gateway_endpoint_id} must be in VPC ${var.vpc_id} and attached to every compute route table (${join(", ", var.route_table_ids)})."
    }
  }
}

# ---------------------------------------------------------------------------
# Interface endpoints — STS always, KMS when a customer-managed key is used.
# ---------------------------------------------------------------------------

resource "aws_security_group" "interface_endpoints" {
  count = local.create_interface_sg ? 1 : 0

  name        = "${var.workspace_name}-endpoints"
  description = "Security group for Databricks workspace interface VPC endpoints"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, {
    Name = "${var.workspace_name}-endpoints"
  })
}

resource "aws_vpc_security_group_ingress_rule" "interface_endpoints_https" {
  count = local.create_interface_sg ? 1 : 0

  security_group_id = aws_security_group.interface_endpoints[0].id

  description = "Allow HTTPS access to interface endpoints from the workspace compute security group"

  ip_protocol = "tcp"
  from_port   = 443
  to_port     = 443

  referenced_security_group_id = var.workspace_security_group_id
}

resource "aws_vpc_endpoint" "sts" {
  count = local.create_sts ? 1 : 0

  vpc_id = var.vpc_id

  service_name      = "com.amazonaws.${var.aws_region}.sts"
  vpc_endpoint_type = "Interface"
  subnet_ids        = local.interface_subnet_ids

  security_group_ids = [
    aws_security_group.interface_endpoints[0].id
  ]

  private_dns_enabled = true

  tags = merge(local.common_tags, {
    Name = "${var.workspace_name}-sts-endpoint"
  })
}

resource "aws_vpc_endpoint" "kms" {
  count = local.create_kms ? 1 : 0

  vpc_id = var.vpc_id

  service_name      = "com.amazonaws.${var.aws_region}.kms"
  vpc_endpoint_type = "Interface"
  subnet_ids        = local.interface_subnet_ids

  security_group_ids = [
    aws_security_group.interface_endpoints[0].id
  ]

  private_dns_enabled = true

  tags = merge(local.common_tags, {
    Name = "${var.workspace_name}-kms-endpoint"
  })
}

moved {
  from = aws_vpc_endpoint.s3
  to   = aws_vpc_endpoint.s3[0]
}

moved {
  from = aws_vpc_endpoint.sts
  to   = aws_vpc_endpoint.sts[0]
}

moved {
  from = aws_security_group.interface_endpoints
  to   = aws_security_group.interface_endpoints[0]
}

moved {
  from = aws_vpc_security_group_ingress_rule.interface_endpoints_https
  to   = aws_vpc_security_group_ingress_rule.interface_endpoints_https[0]
}
