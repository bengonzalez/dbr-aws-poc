resource "aws_kms_key" "databricks" {
  description             = "KMS key for ${var.project_name}"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = {
    Name    = "${var.project_name}-kms-key"
    Project = var.project_name
  }
}

resource "aws_kms_alias" "databricks" {
  name          = "alias/${var.project_name}"
  target_key_id = aws_kms_key.databricks.key_id
}