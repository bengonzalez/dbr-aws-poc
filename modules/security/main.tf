/*
For our initial POC, we're using EC2 as the trusted service 
because Databricks classic compute ultimately runs on AWS compute resources.

Important: this is an initial POC trust relationship. 
We will revisit the exact Databricks trust configuration 
when we integrate the actual Databricks workspace. 
I don't want us to prematurely lock the architecture 
to an incorrect Databricks-specific trust relationship.
*/

data "aws_iam_policy_document" "databricks_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }

    actions = [
      "sts:AssumeRole"
    ]
  }
}

resource "aws_iam_role" "databricks" {
  name = "${var.project_name}-databricks-role"

  assume_role_policy = data.aws_iam_policy_document.databricks_assume_role.json

  tags = {
    Name    = "${var.project_name}-databricks-role"
    Project = var.project_name
  }
}

data "aws_iam_policy_document" "databricks_s3" {
  statement {
    effect = "Allow"

    actions = [
      "s3:ListBucket"
    ]

    resources = [
      var.data_bucket_arn
    ]
  }

  statement {
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject"
    ]

    resources = [
      "${var.data_bucket_arn}/*"
    ]
  }
}

resource "aws_iam_policy" "databricks_s3" {
  name        = "${var.project_name}-databricks-s3"
  description = "S3 access for ${var.project_name} Databricks"

  policy = data.aws_iam_policy_document.databricks_s3.json
}

resource "aws_iam_role_policy_attachment" "databricks_s3" {
  role       = aws_iam_role.databricks.name
  policy_arn = aws_iam_policy.databricks_s3.arn
}

data "aws_iam_policy_document" "databricks_kms" {
  statement {
    effect = "Allow"

    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey"
    ]

    resources = [
      var.kms_key_arn
    ]
  }
}

resource "aws_iam_policy" "databricks_kms" {
  name        = "${var.project_name}-databricks-kms"
  description = "KMS access for ${var.project_name} Databricks"

  policy = data.aws_iam_policy_document.databricks_kms.json
}

resource "aws_iam_role_policy_attachment" "databricks_kms" {
  role       = aws_iam_role.databricks.name
  policy_arn = aws_iam_policy.databricks_kms.arn
}