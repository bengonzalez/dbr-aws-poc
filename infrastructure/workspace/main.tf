module "workspace_network" {
  source = "../../modules/workspace-network"

  workspace_name = local.workspace_name

  vpc_id = var.platform.vpc_id

  private_subnets = var.network.requirements.subnets.private

  route_table_ids = var.platform.route_table_ids

  tags = local.common_tags
}

resource "databricks_mws_networks" "workspace" {
  provider = databricks.mws

  account_id   = var.databricks_account_id
  network_name = "${local.workspace_name}-network"

  vpc_id             = module.workspace_network.vpc_id
  subnet_ids         = module.workspace_network.private_subnet_ids
  security_group_ids = [module.workspace_network.security_group_id]

  depends_on = [
    module.workspace_network
  ]
}

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

    vpc_id = module.workspace_network.vpc_id

    private_subnet_ids = join(
      ",",
      module.workspace_network.private_subnet_ids
    )

    security_group_id = module.workspace_network.security_group_id
  }
}