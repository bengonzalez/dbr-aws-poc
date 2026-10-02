# Quick validation of the resolved network configuration
resource "terraform_data" "workspace_configuration" {
  input = {
    workspace_name       = local.workspace_name
    environment          = local.environment
    network_strategy     = local.resolved_network.strategy
    vpc_id               = local.resolved_network.vpc_id
    private_subnet_count = length(local.resolved_network.private_subnet_ids)
    security_group_id    = local.resolved_network.security_group_id
  }
}