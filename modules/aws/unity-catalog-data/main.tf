
# Dedicated S3 bucket for Unity Catalog managed table storage - separate
# from the workspace root bucket (modules/workspace-deployment/s3.tf),
# matching the "application data storage is separate from workspace root"
# baseline (CLAUDE.md Sec6).
resource "aws_s3_bucket" "unity_catalog_data" {
  bucket = local.uc_bucket_name

  tags = merge(local.common_tags, {
    Name      = "${var.workspace_name}-uc-data"
    Component = "unity-catalog-data-storage"
  })
}

resource "aws_s3_bucket_public_access_block" "unity_catalog_data" {
  bucket = aws_s3_bucket.unity_catalog_data.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# Customer-managed key for the Unity Catalog bucket - the third key in the
# SRA-style 3-key split (CLAUDE.md Sec7), gated on encryption.application_data
# rather than encryption.workspace (modules/workspace-kms's two keys). Kept
# self-contained here rather than folded into workspace-kms: its policy
# grants the UC IAM role below access, a different principal/shape than
# workspace-kms's two keys.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "unity_catalog" {
  count = var.encryption_customer_managed ? 1 : 0

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
    sid    = "AllowUnityCatalogRoleToUseKey"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.unity_catalog.arn]
    }

    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]

    resources = ["*"]
  }
}

resource "aws_kms_key" "unity_catalog" {
  count = var.encryption_customer_managed ? 1 : 0

  description         = "Customer-managed key for ${var.workspace_name} Unity Catalog storage."
  enable_key_rotation = true
  policy              = data.aws_iam_policy_document.unity_catalog[0].json

  tags = merge(local.common_tags, {
    Name = "${var.workspace_name}-uc-key"
  })
}

resource "aws_kms_alias" "unity_catalog" {
  count = var.encryption_customer_managed ? 1 : 0

  name          = "alias/${var.workspace_name}-uc-key"
  target_key_id = aws_kms_key.unity_catalog[0].key_id
}

# ---------------------------------------------------------------------------
# Storage credential, IAM role, and external location - bootstrapped in the
# order verified against databricks/terraform-databricks-sra's own
# unity_catalog_catalog_creation module (CLAUDE.md Sec8): the storage
# credential references the role by a predictable ARN STRING (not a
# resource reference), breaking what would otherwise be a dependency cycle
# (the role's trust policy needs the credential's generated external_id,
# which doesn't exist until the credential itself is created).
# ---------------------------------------------------------------------------

resource "databricks_storage_credential" "this" {
  provider = databricks.mws

  name           = "${var.workspace_name}-uc-storage-credential"
  metastore_id   = var.existing_metastore_id
  isolation_mode = "ISOLATION_MODE_ISOLATED"
  force_destroy  = true

  aws_iam_role {
    role_arn = "arn:aws:iam::${var.aws_account_id}:role/${local.uc_role_name}"
  }

  provider_config {
    workspace_id = var.databricks_workspace_id
  }
}

# Unlike databricks_catalog's isolation_mode (which auto-binds to its
# creating workspace per the provider's own docs), storage_credential and
# external_location's isolation_mode does NOT auto-bind - confirmed
# empirically (2026-10-14, real apply against isolated-proof): the
# external_location below failed with "Credential ... is not accessible
# in current workspace" without this explicit binding. Neither resource's
# docs ever claimed auto-bind the way catalog's did, so this is now the
# explicit, non-ambiguous fix rather than relying on undocumented behavior.
resource "databricks_workspace_binding" "storage_credential" {
  provider = databricks.mws

  securable_name = databricks_storage_credential.this.name
  securable_type = "storage_credential"
  workspace_id   = var.databricks_workspace_id

  provider_config {
    workspace_id = var.databricks_workspace_id
  }
}

data "databricks_aws_unity_catalog_assume_role_policy" "this" {
  provider = databricks.mws

  aws_account_id = var.aws_account_id
  role_name      = local.uc_role_name
  external_id    = databricks_storage_credential.this.aws_iam_role[0].external_id
}

data "databricks_aws_unity_catalog_policy" "this" {
  provider = databricks.mws

  aws_account_id = var.aws_account_id
  bucket_name    = aws_s3_bucket.unity_catalog_data.id
  role_name      = local.uc_role_name

  kms_name = (
    var.encryption_customer_managed ? aws_kms_key.unity_catalog[0].arn : null
  )
}

resource "aws_iam_role" "unity_catalog" {
  name               = local.uc_role_name
  description        = "Unity Catalog data access role for ${var.workspace_name}"
  assume_role_policy = data.databricks_aws_unity_catalog_assume_role_policy.this.json

  tags = local.common_tags
}

resource "aws_iam_policy" "unity_catalog" {
  name   = "${local.uc_role_name}-policy"
  policy = data.databricks_aws_unity_catalog_policy.this.json
}

resource "aws_iam_role_policy_attachment" "unity_catalog" {
  role       = aws_iam_role.unity_catalog.name
  policy_arn = aws_iam_policy.unity_catalog.arn
}

# IAM trust-policy propagation lag (CLAUDE.md Sec4a's already-identified
# TODO, applied here for real for the first time) - the external location
# below needs to actually assume this role to validate.
resource "time_sleep" "unity_catalog_iam_propagation" {
  create_duration = "60s"

  depends_on = [
    aws_iam_role_policy_attachment.unity_catalog
  ]
}

resource "databricks_external_location" "this" {
  provider = databricks.mws

  name            = "${var.workspace_name}-uc-external-location"
  url             = "s3://${aws_s3_bucket.unity_catalog_data.id}/"
  credential_name = databricks_storage_credential.this.name
  isolation_mode  = "ISOLATION_MODE_ISOLATED"
  comment         = "Managed by Terraform for workspace ${var.workspace_name}."

  dynamic "encryption_details" {
    for_each = var.encryption_customer_managed ? [1] : []

    content {
      sse_encryption_details {
        algorithm       = "AWS_SSE_KMS"
        aws_kms_key_arn = aws_kms_key.unity_catalog[0].arn
      }
    }
  }

  provider_config {
    workspace_id = var.databricks_workspace_id
  }

  depends_on = [
    time_sleep.unity_catalog_iam_propagation,
    databricks_workspace_binding.storage_credential,
  ]
}

# Same reasoning as the storage_credential binding above - the external
# location's own isolation_mode doesn't auto-bind either.
resource "databricks_workspace_binding" "external_location" {
  provider = databricks.mws

  securable_name = databricks_external_location.this.name
  securable_type = "external_location"
  workspace_id   = var.databricks_workspace_id

  provider_config {
    workspace_id = var.databricks_workspace_id
  }
}
