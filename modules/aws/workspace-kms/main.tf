locals {
  # Databricks' AWS account root for the standard (commercial, non-GovCloud) control plane.
  # Scopes which Databricks-owned principal may use these keys; actual access is narrowed
  # further by the DatabricksAccountId condition on each statement below.
  databricks_control_plane_account_id = "414351767826"

  create_workspace_storage_key = var.existing_workspace_storage_key_arn == null
  create_managed_services_key  = var.existing_managed_services_key_arn == null

  common_tags = merge(
    var.tags,
    {
      ManagedBy = "terraform"
      Component = "databricks-workspace-kms"
      Workspace = var.workspace_name
    }
  )
}

# ---------------------------------------------------------------------------
# Workspace storage key — encrypts DBFS/workspace root storage and, via the
# cross-account role, EBS volumes backing classic compute. Either created
# here, or an existing customer-supplied key is used as-is (the customer is
# then responsible for that key's policy granting Databricks access).
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "workspace_storage" {
  count = local.create_workspace_storage_key ? 1 : 0

  statement {
    sid    = "EnableIAMUserPermissions"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.aws_account_id}:root"]
    }

    actions   = ["kms:*"]
    resources = ["*"]
  }

  statement {
    sid    = "AllowDatabricksToUseKeyForDBFS"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.databricks_control_plane_account_id}:root"]
    }

    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalTag/DatabricksAccountId"
      values   = [var.databricks_account_id]
    }
  }

  statement {
    sid    = "AllowCrossAccountRoleToUseKeyForEBS"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [var.cross_account_role_arn]
    }

    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey*",
      "kms:CreateGrant",
      "kms:DescribeKey",
    ]

    resources = ["*"]

    condition {
      test     = "ForAnyValue:StringLike"
      variable = "kms:ViaService"
      values   = ["ec2.*.amazonaws.com"]
    }
  }
}

resource "aws_kms_key" "workspace_storage" {
  count = local.create_workspace_storage_key ? 1 : 0

  description         = "Customer-managed key for ${var.workspace_name} workspace storage (DBFS/root bucket, EBS)."
  enable_key_rotation = true
  policy              = data.aws_iam_policy_document.workspace_storage[0].json

  tags = merge(local.common_tags, {
    Name = "${var.workspace_name}-workspace-storage-key"
  })
}

resource "aws_kms_alias" "workspace_storage" {
  count = local.create_workspace_storage_key ? 1 : 0

  name          = "alias/${var.workspace_name}-workspace-storage-key"
  target_key_id = aws_kms_key.workspace_storage[0].key_id
}

# ---------------------------------------------------------------------------
# Managed services key — encrypts Databricks control-plane managed data for
# this workspace (notebook source, secrets, job/notebook results, etc). Same
# existing-or-create choice as the storage key above.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "managed_services" {
  count = local.create_managed_services_key ? 1 : 0

  statement {
    sid    = "EnableIAMUserPermissions"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.aws_account_id}:root"]
    }

    actions   = ["kms:*"]
    resources = ["*"]
  }

  statement {
    sid    = "AllowDatabricksToUseKeyForManagedServices"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.databricks_control_plane_account_id}:root"]
    }

    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
    ]

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalTag/DatabricksAccountId"
      values   = [var.databricks_account_id]
    }
  }
}

resource "aws_kms_key" "managed_services" {
  count = local.create_managed_services_key ? 1 : 0

  description         = "Customer-managed key for ${var.workspace_name} managed services (control plane)."
  enable_key_rotation = true
  policy              = data.aws_iam_policy_document.managed_services[0].json

  tags = merge(local.common_tags, {
    Name = "${var.workspace_name}-managed-services-key"
  })
}

resource "aws_kms_alias" "managed_services" {
  count = local.create_managed_services_key ? 1 : 0

  name          = "alias/${var.workspace_name}-managed-services-key"
  target_key_id = aws_kms_key.managed_services[0].key_id
}
