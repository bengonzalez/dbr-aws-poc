data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "databricks_storage_cmk" {
  version = "2012-10-17"

statement {
  sid    = "EnableIAMUserPermissions"
  effect = "Allow"

  principals {
    type        = "AWS"
    identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
  }

  actions   = ["kms:*"]
  resources = ["*"]
}

  statement {
    sid    = "AllowDatabricksToUseKMSKeyForDBFS"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::414351767826:root"]
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
    sid    = "AllowDatabricksToUseKMSKeyForEBS"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [var.databricks_cross_account_role]
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

resource "aws_kms_key" "databricks" {
  description             = "KMS key for ${var.project_name}"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = data.aws_iam_policy_document.databricks_storage_cmk.json

  tags = {
    Name    = "${var.project_name}-kms-key"
    Project = var.project_name
  }
}

resource "aws_kms_alias" "databricks" {
  name          = "alias/${var.project_name}"
  target_key_id = aws_kms_key.databricks.key_id
}