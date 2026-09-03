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