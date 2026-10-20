output "rest_api_vpc_endpoint_id" {
  description = "Databricks-registered VPC endpoint id for the REST API (general access) endpoint."
  value       = databricks_mws_vpc_endpoint.general_access.vpc_endpoint_id
}

output "dataplane_relay_vpc_endpoint_id" {
  description = "Databricks-registered VPC endpoint id for the Secure Cluster Connectivity relay endpoint."
  value       = databricks_mws_vpc_endpoint.scc_relay.vpc_endpoint_id
}

output "private_access_settings_id" {
  description = "Private access settings id, used to disable public access on the workspace."
  value       = databricks_mws_private_access_settings.this.private_access_settings_id
}

output "privatelink_security_group_id" {
  description = "Security group used by the PrivateLink interface endpoints."
  value       = aws_security_group.privatelink.id
}
