
locals {
  role_name = substr(
    "${var.workspace_name}-crossaccount",
    0,
    64
  )

  common_tags = merge(
    var.tags,
    {
      Name      = substr("${var.workspace_name}-crossaccount", 0, 128)
      ManagedBy = "terraform"
      Component = "databricks-workspace-iam"
    }
  )
}

# Generate the Databricks-required trust policy.
data "databricks_aws_assume_role_policy" "this" {
  provider = databricks.mws

  external_id = var.databricks_account_id
}

# Generate permissions for a customer-managed VPC.

data "databricks_aws_crossaccount_policy" "this" {
  provider = databricks.mws

  policy_type       = "restricted"
  aws_account_id    = var.aws_account_id
  region            = var.aws_region
  vpc_id            = var.vpc_id
  security_group_id = var.databricks_security_group_id
}

resource "aws_iam_role" "cross_account" {
  name               = local.role_name
  description        = "Databricks cross-account role for ${var.workspace_name}"
  assume_role_policy = data.databricks_aws_assume_role_policy.this.json

  tags = local.common_tags
}

resource "aws_iam_role_policy" "cross_account" {
  name   = "${var.workspace_name}-crossaccount"
  role   = aws_iam_role.cross_account.id
  policy = data.databricks_aws_crossaccount_policy.this.json
}