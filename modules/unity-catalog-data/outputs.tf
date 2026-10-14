
output "bucket_name" {
  description = "Name of the S3 bucket used for Unity Catalog managed storage."
  value       = aws_s3_bucket.unity_catalog_data.id
}

output "bucket_arn" {
  description = "ARN of the S3 bucket used for Unity Catalog managed storage."
  value       = aws_s3_bucket.unity_catalog_data.arn
}

output "storage_credential_name" {
  description = "Name of the Unity Catalog storage credential."
  value       = databricks_storage_credential.this.name
}

output "external_location_name" {
  description = "Name of the Unity Catalog external location."
  value       = databricks_external_location.this.name
}

output "kms_key_arn" {
  description = "ARN of the customer-managed KMS key for Unity Catalog storage, when encryption_customer_managed is true; null otherwise."
  value       = var.encryption_customer_managed ? aws_kms_key.unity_catalog[0].arn : null
}
