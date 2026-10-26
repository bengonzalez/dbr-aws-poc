output "s3_endpoint_id" {
  description = "ID of the S3 gateway VPC endpoint (created, or the client's)."
  value       = local.create_s3 ? aws_vpc_endpoint.s3[0].id : var.existing_s3_gateway_endpoint_id
}

output "sts_endpoint_id" {
  description = "ID of the STS interface VPC endpoint (created, or the client's)."
  value       = local.create_sts ? aws_vpc_endpoint.sts[0].id : var.existing_sts_endpoint_id
}

output "kms_endpoint_id" {
  description = "ID of the KMS interface VPC endpoint (created, or the client's), when one is needed."
  value = (
    !var.enable_kms_endpoint ? null :
    local.create_kms ? aws_vpc_endpoint.kms[0].id : var.existing_kms_endpoint_id
  )
}

output "interface_endpoints_security_group_id" {
  description = "Security group used by the interface VPC endpoints this module created; null when it created none."
  value       = local.create_interface_sg ? aws_security_group.interface_endpoints[0].id : null
}
