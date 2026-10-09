
# Dedicated S3 bucket for Databricks workspace root storage.
resource "aws_s3_bucket" "workspace_root" {
  bucket = "${local.workspace_name}-${data.aws_caller_identity.current.account_id}-${var.cloud.region}-root"

  tags = merge(local.common_tags, {
    Name      = "${local.workspace_name}-root"
    Component = "databricks-workspace-root-storage"
  })
}

# Encryption follows the resolved profile: customer-managed KMS when required
# (e.g. live), AWS-managed SSE-S3 otherwise (e.g. dev/stage).
resource "aws_s3_bucket_server_side_encryption_configuration" "workspace_root" {
  bucket = aws_s3_bucket.workspace_root.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = (
        var.encryption.workspace == "customer_managed" ? "aws:kms" : "AES256"
      )

      kms_master_key_id = (
        var.encryption.workspace == "customer_managed" ?
        module.workspace_kms[0].workspace_storage_key_arn : null
      )
    }

    bucket_key_enabled = var.encryption.workspace == "customer_managed" ? true : null
  }
}

# Prevent public access to the bucket.
resource "aws_s3_bucket_public_access_block" "workspace_root" {
  bucket = aws_s3_bucket.workspace_root.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Ask the Databricks provider for the required bucket policy.
data "databricks_aws_bucket_policy" "workspace_root" {
  bucket                   = aws_s3_bucket.workspace_root.bucket
  databricks_e2_account_id = var.databricks_account_id
}

resource "aws_s3_bucket_policy" "workspace_root" {
  bucket = aws_s3_bucket.workspace_root.id
  policy = data.databricks_aws_bucket_policy.workspace_root.json

  depends_on = [
    aws_s3_bucket_public_access_block.workspace_root
  ]
}

# Register the bucket with the Databricks account.
resource "databricks_mws_storage_configurations" "workspace_root" {
  provider = databricks.mws

  account_id                 = var.databricks_account_id
  storage_configuration_name = "${local.workspace_name}-storage"
  bucket_name                = aws_s3_bucket.workspace_root.bucket

  depends_on = [
    aws_s3_bucket_policy.workspace_root
  ]
}