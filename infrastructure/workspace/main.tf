# Quick validation of the resolved network configuration
resource "terraform_data" "workspace_configuration" {
  input = {
    workspace_name       = local.workspace_name
    environment          = local.environment
    network_strategy     = local.resolved_network.strategy
    network_architecture = local.resolved_network.architecture

    vpc_ownership = local.resolved_network.vpc.ownership

    subnet_ownership = local.resolved_network.subnets.ownership

    routing_ownership = local.resolved_network.routing.ownership

    security_group_ownership = (
      local.resolved_network.security_groups.ownership
    )

    endpoint_ownership = (
      local.resolved_network.endpoints.ownership
    )
  }
}