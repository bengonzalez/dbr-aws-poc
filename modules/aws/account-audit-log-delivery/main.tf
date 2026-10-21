# Account-level audit log delivery (CLAUDE.md §10 backlog item #1 / §8
# milestone 39) - delivers EVERY workspace's audit logs on this
# Databricks account to one dedicated S3 bucket. Mirrors SRA's own
# aws/tf/modules/databricks_account/audit_log_delivery module almost
# exactly (fetched and verified against SRA's source this session, not
# guessed), adapted to this project's naming/provider-alias conventions.

resource "aws_s3_bucket" "log_delivery" {
  bucket = local.bucket_name

  # Audit logs are append-only and reconstructable from Databricks'
  # account console if ever lost - force_destroy matches SRA's own
  # choice, since there's no reason to block teardown of a log bucket
  # the way this project deliberately blocks it for workspace-root/UC
  # data buckets (see CLAUDE.md §8 milestone 34).
  force_destroy = true

  tags = local.common_tags
}

resource "aws_s3_bucket_public_access_block" "log_delivery" {
  bucket = aws_s3_bucket.log_delivery.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "log_delivery" {
  bucket = aws_s3_bucket.log_delivery.id

  versioning_configuration {
    status = "Disabled"
  }
}

data "databricks_aws_bucket_policy" "log_delivery" {
  provider = databricks.mws

  full_access_role = aws_iam_role.log_delivery.arn
  aws_partition    = var.aws_assume_partition
  bucket           = aws_s3_bucket.log_delivery.bucket
}

resource "aws_s3_bucket_policy" "log_delivery" {
  bucket = aws_s3_bucket.log_delivery.id
  policy = data.databricks_aws_bucket_policy.log_delivery.json
}

data "databricks_aws_assume_role_policy" "log_delivery" {
  provider = databricks.mws

  external_id      = var.databricks_account_id
  for_log_delivery = true
  aws_partition    = var.aws_assume_partition
}

resource "aws_iam_role" "log_delivery" {
  name               = "${var.resource_prefix}-audit-log-delivery-role"
  description        = "(${var.resource_prefix}) Databricks account audit log delivery role"
  assume_role_policy = data.databricks_aws_assume_role_policy.log_delivery.json

  tags = local.common_tags
}

# Grants the log delivery role explicit S3 permissions on the bucket,
# matching Databricks' documented log delivery credential setup -
# required in addition to the bucket policy above. Object-level
# statements are scoped to the delivery_path_prefix ("audit-logs") used
# by databricks_mws_log_delivery below.
resource "aws_iam_role_policy" "log_delivery" {
  name = "${var.resource_prefix}-audit-log-delivery-inline"
  role = aws_iam_role.log_delivery.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "GetBucketLocation"
        Effect   = "Allow"
        Action   = ["s3:GetBucketLocation"]
        Resource = aws_s3_bucket.log_delivery.arn
      },
      {
        Sid    = "ObjectAccess"
        Effect = "Allow"
        Action = [
          "s3:AbortMultipartUpload",
          "s3:DeleteObject",
          "s3:GetObject",
          "s3:ListMultipartUploadParts",
          "s3:PutObject",
          "s3:PutObjectAcl",
        ]
        Resource = [
          "${aws_s3_bucket.log_delivery.arn}/audit-logs/",
          "${aws_s3_bucket.log_delivery.arn}/audit-logs/*",
        ]
      },
      {
        Sid      = "ListBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:ListBucketMultipartUploads"]
        Resource = aws_s3_bucket.log_delivery.arn
      },
    ]
  })
}

# Same class of IAM-propagation-lag fix already used elsewhere in this
# project (e.g. modules/aws/unity-catalog-data's time_sleep) - gives the
# role/policy time to propagate before Databricks tries to assume it.
resource "time_sleep" "iam_propagation" {
  depends_on = [
    aws_iam_role.log_delivery,
    aws_iam_role_policy.log_delivery,
  ]

  create_duration = "10s"
}

resource "databricks_mws_credentials" "log_delivery" {
  provider = databricks.mws

  credentials_name = "${var.resource_prefix}-audit-log-delivery-credential"
  role_arn         = aws_iam_role.log_delivery.arn

  depends_on = [time_sleep.iam_propagation]
}

resource "databricks_mws_storage_configurations" "log_delivery" {
  provider = databricks.mws

  account_id                 = var.databricks_account_id
  storage_configuration_name = "${var.resource_prefix}-audit-log-delivery-storage"
  bucket_name                = aws_s3_bucket.log_delivery.bucket
}

resource "databricks_mws_log_delivery" "audit_logs" {
  provider = databricks.mws

  account_id               = var.databricks_account_id
  credentials_id           = databricks_mws_credentials.log_delivery.credentials_id
  storage_configuration_id = databricks_mws_storage_configurations.log_delivery.storage_configuration_id
  delivery_path_prefix     = "audit-logs"
  config_name              = "${var.resource_prefix}-audit-logs"
  log_type                 = "AUDIT_LOGS"
  output_format            = "JSON"
}
