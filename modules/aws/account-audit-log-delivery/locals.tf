locals {
  bucket_name = "${var.resource_prefix}-audit-log-delivery"

  common_tags = merge(
    var.tags,
    {
      Name      = local.bucket_name
      ManagedBy = "terraform"
      Component = "account-audit-log-delivery"
    }
  )
}
