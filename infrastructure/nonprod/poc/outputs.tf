# Networking outputs
output "vpc_id" {
  description = "ID of the POC VPC"
  value       = module.networking.vpc_id
}

output "public_subnet_id" {
  description = "Public subnet ID"
  value       = module.networking.public_subnet_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = module.networking.private_subnet_ids
}

output "databricks_security_group_id" {
  description = "Security group intended for Databricks compute"
  value       = module.networking.databricks_security_group_id
}

output "private_route_table_id" {
  description = "ID of the private route table"
  value       = module.networking.private_route_table_id
}

# Endpoints outputs
output "kms_endpoint_id" {
  description = "ID of the KMS VPC endpoint"
  value       = module.endpoints.kms_endpoint_id
}

output "endpoint_security_group_id" {
  description = "Security group ID used by interface VPC endpoints"
  value       = module.endpoints.endpoint_security_group_id
}

# KMS outputs
output "kms_key_id" {
  description = "ID of the Databricks KMS key"
  value       = module.kms.kms_key_id
}

output "kms_key_arn" {
  description = "ARN of the Databricks KMS key"
  value       = module.kms.kms_key_arn
}

output "kms_alias_arn" {
  description = "ARN of the Databricks KMS alias"
  value       = module.kms.kms_alias_arn
}

output "data_bucket_name" {
  description = "Name of the Databricks data bucket"
  value       = module.storage.data_bucket_id
}

# Storage outputs
output "data_bucket_arn" {
  description = "ARN of the Databricks data bucket"
  value       = module.storage.data_bucket_arn
}

output "databricks_role_name" {
  description = "Name of the Databricks IAM role"
  value       = module.security.databricks_role_name
}

output "databricks_role_arn" {
  description = "ARN of the Databricks IAM role"
  value       = module.security.databricks_role_arn
}

output "databricks_workspace_role_arn" {
  description = "ARN of the Databricks workspace cross-account IAM role"
  value       = module.security.databricks_workspace_role_arn
}