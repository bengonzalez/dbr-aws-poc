# Quick validation of the resolved network configuration
resource "terraform_data" "workspace_configuration" {
  input = {
    workspace_name = local.workspace_name
    environment    = local.environment

    network_strategy     = var.network.strategy
    network_architecture = var.network.architecture

    vpc_ownership = (
      var.network.requirements.vpc.ownership
    )

    subnet_ownership = (
      var.network.requirements.subnets.ownership
    )

    routing_ownership = (
      var.network.requirements.routing.ownership
    )

    security_group_ownership = (
      var.network.requirements.security_groups.ownership
    )

    endpoint_ownership = (
      var.network.requirements.endpoints.ownership
    )
  }
}