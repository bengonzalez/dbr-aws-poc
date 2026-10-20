output "kms_key_id" {
  description = "ID of the KMS key"
  value       = aws_kms_key.databricks.key_id
}

output "kms_key_arn" {
  description = "ARN of the KMS key"
  value       = aws_kms_key.databricks.arn
}

output "kms_alias_arn" {
  description = "ARN of the KMS alias"
  value       = aws_kms_alias.databricks.arn
}