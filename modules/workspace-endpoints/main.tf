locals {
  common_tags = merge(
    var.tags,
    {
      ManagedBy = "terraform"
      Component = "databricks-workspace-endpoints"
      Workspace = var.workspace_name
    }
  )
}

# ---------------------------------------------------------------------------
# S3 gateway endpoint — DBFS/root bucket access with no NAT/IGW in the VPC.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "s3_endpoint" {
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
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = var.route_table_ids
  policy            = data.aws_iam_policy_document.s3_endpoint.json

  tags = merge(local.common_tags, {
    Name = "${var.workspace_name}-s3-endpoint"
  })
}

# ---------------------------------------------------------------------------
# Interface endpoints — STS always, KMS when a customer-managed key is used.
# ---------------------------------------------------------------------------

resource "aws_security_group" "interface_endpoints" {
  name        = "${var.workspace_name}-endpoints"
  description = "Security group for Databricks workspace interface VPC endpoints"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, {
    Name = "${var.workspace_name}-endpoints"
  })
}

resource "aws_vpc_security_group_ingress_rule" "interface_endpoints_https" {
  security_group_id = aws_security_group.interface_endpoints.id

  description = "Allow HTTPS access to interface endpoints from the VPC"

  ip_protocol = "tcp"
  from_port   = 443
  to_port     = 443

  cidr_ipv4 = var.vpc_cidr
}

resource "aws_vpc_endpoint" "sts" {
  vpc_id = var.vpc_id

  service_name      = "com.amazonaws.${var.aws_region}.sts"
  vpc_endpoint_type = "Interface"
  subnet_ids        = var.private_subnet_ids

  security_group_ids = [
    aws_security_group.interface_endpoints.id
  ]

  private_dns_enabled = true

  tags = merge(local.common_tags, {
    Name = "${var.workspace_name}-sts-endpoint"
  })
}

resource "aws_vpc_endpoint" "kms" {
  count = var.enable_kms_endpoint ? 1 : 0

  vpc_id = var.vpc_id

  service_name      = "com.amazonaws.${var.aws_region}.kms"
  vpc_endpoint_type = "Interface"
  subnet_ids        = var.private_subnet_ids

  security_group_ids = [
    aws_security_group.interface_endpoints.id
  ]

  private_dns_enabled = true

  tags = merge(local.common_tags, {
    Name = "${var.workspace_name}-kms-endpoint"
  })
}
