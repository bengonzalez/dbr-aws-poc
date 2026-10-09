output "workspace_storage_key_arn" {
  description = "ARN of the workspace storage KMS key (created here, or the existing one supplied)."
  value = (
    local.create_workspace_storage_key ?
    aws_kms_key.workspace_storage[0].arn : var.existing_workspace_storage_key_arn
  )
}

output "workspace_storage_key_alias_name" {
  description = "Alias name of the workspace storage KMS key (created here, or the existing one supplied)."
  value = (
    local.create_workspace_storage_key ?
    aws_kms_alias.workspace_storage[0].name : var.existing_workspace_storage_key_alias
  )
}

output "managed_services_key_arn" {
  description = "ARN of the managed services KMS key (created here, or the existing one supplied)."
  value = (
    local.create_managed_services_key ?
    aws_kms_key.managed_services[0].arn : var.existing_managed_services_key_arn
  )
}

output "managed_services_key_alias_name" {
  description = "Alias name of the managed services KMS key (created here, or the existing one supplied)."
  value = (
    local.create_managed_services_key ?
    aws_kms_alias.managed_services[0].name : var.existing_managed_services_key_alias
  )
}
