module "workspace_network" {
  source = "../../modules/workspace-network"

  workspace_name = local.workspace_name

  existing_vpc_id = local.vpc_ownership == "existing" ? var.platform.vpc_id : null
  vpc_cidr        = local.vpc_ownership == "terraform" ? var.vpc_cidr : null

  private_subnets = var.network.requirements.subnets.private

  existing_route_table_ids = local.routing_ownership == "existing" ? var.platform.route_table_ids : null

  existing_security_group_id = local.security_group_ownership == "existing" ? var.existing_security_group_id : null

  tags = local.common_tags
}

# VPC endpoints (S3 gateway + STS, and KMS when a customer-managed key is in
# use), needed whenever networking has no NAT/IGW — i.e. whenever endpoints
# ownership resolves to 'terraform' (isolated by default).
module "workspace_endpoints" {
  count  = local.endpoints_ownership == "terraform" ? 1 : 0
  source = "../../modules/workspace-endpoints"

  workspace_name = local.workspace_name

  vpc_id   = module.workspace_network.vpc_id
  vpc_cidr = module.workspace_network.vpc_cidr

  aws_region = var.cloud.region

  route_table_ids     = module.workspace_network.route_table_ids
  private_subnet_ids  = module.workspace_network.private_subnet_ids
  s3_bucket_arns      = [aws_s3_bucket.workspace_root.arn]
  enable_kms_endpoint = var.encryption.workspace == "customer_managed"

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



resource "databricks_mws_credentials" "workspace" {
  provider = databricks.mws

  credentials_name = "${local.workspace_name}-credentials"
  role_arn         = module.workspace_iam_role.role_arn

  depends_on = [
    module.workspace_iam_role
  ]
}

module "workspace_iam_role" {
  source = "../../modules/workspace-iam-role"

  providers = {
    databricks.mws = databricks.mws
  }

  workspace_name               = local.workspace_name
  databricks_account_id        = var.databricks_account_id
  aws_account_id               = data.aws_caller_identity.current.account_id
  aws_region                   = var.cloud.region
  vpc_id                       = module.workspace_network.vpc_id
  databricks_security_group_id = module.workspace_network.security_group_id

  tags = local.common_tags
}

# Customer-managed KMS keys, provisioned only when the resolved profile
# requires customer-managed workspace encryption (currently: live).
module "workspace_kms" {
  count  = var.encryption.workspace == "customer_managed" ? 1 : 0
  source = "../../modules/workspace-kms"

  workspace_name         = local.workspace_name
  databricks_account_id  = var.databricks_account_id
  aws_account_id         = data.aws_caller_identity.current.account_id
  cross_account_role_arn = module.workspace_iam_role.role_arn

  existing_workspace_storage_key_arn   = var.existing_workspace_storage_key_arn
  existing_workspace_storage_key_alias = var.existing_workspace_storage_key_alias
  existing_managed_services_key_arn    = var.existing_managed_services_key_arn
  existing_managed_services_key_alias  = var.existing_managed_services_key_alias

  tags = local.common_tags
}

# Register the customer-managed keys with the Databricks account so they can
# be attached to the workspace below. Only created when the resolved profile
# requires customer-managed workspace encryption (currently: live).
resource "databricks_mws_customer_managed_keys" "storage" {
  count    = var.encryption.workspace == "customer_managed" ? 1 : 0
  provider = databricks.mws

  account_id = var.databricks_account_id

  aws_key_info {
    key_arn   = module.workspace_kms[0].workspace_storage_key_arn
    key_alias = module.workspace_kms[0].workspace_storage_key_alias_name
  }

  use_cases = ["STORAGE"]
}

resource "databricks_mws_customer_managed_keys" "managed_services" {
  count    = var.encryption.workspace == "customer_managed" ? 1 : 0
  provider = databricks.mws

  account_id = var.databricks_account_id

  aws_key_info {
    key_arn   = module.workspace_kms[0].managed_services_key_arn
    key_alias = module.workspace_kms[0].managed_services_key_alias_name
  }

  use_cases = ["MANAGED_SERVICES"]
}

# The Databricks workspace itself.
resource "databricks_mws_workspaces" "this" {
  provider = databricks.mws

  account_id     = var.databricks_account_id
  workspace_name = local.workspace_name
  aws_region     = var.cloud.region

  credentials_id           = databricks_mws_credentials.workspace.credentials_id
  storage_configuration_id = databricks_mws_storage_configurations.workspace_root.storage_configuration_id
  network_id               = databricks_mws_networks.workspace.network_id

  storage_customer_managed_key_id = (
    var.encryption.workspace == "customer_managed" ?
    databricks_mws_customer_managed_keys.storage[0].customer_managed_key_id : null
  )

  managed_services_customer_managed_key_id = (
    var.encryption.workspace == "customer_managed" ?
    databricks_mws_customer_managed_keys.managed_services[0].customer_managed_key_id : null
  )

  custom_tags = local.common_tags

  depends_on = [
    databricks_mws_credentials.workspace,
    databricks_mws_storage_configurations.workspace_root,
    databricks_mws_networks.workspace,
  ]
}