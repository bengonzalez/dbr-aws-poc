
locals {
  uc_role_name = substr(
    "${var.workspace_name}-uc-access",
    0,
    64
  )

  uc_bucket_name = "${var.workspace_name}-${var.aws_account_id}-${var.aws_region}-uc"

  common_tags = merge(
    var.tags,
    {
      Name      = substr("${var.workspace_name}-uc-data", 0, 128)
      ManagedBy = "terraform"
      Component = "unity-catalog-data"
      Workspace = var.workspace_name
    }
  )
}
