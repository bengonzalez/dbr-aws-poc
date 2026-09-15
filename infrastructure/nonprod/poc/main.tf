module "networking" {
  source = "../../../modules/networking"

  project_name        = var.project_name
  vpc_cidr            = var.vpc_cidr
  public_subnet_cidr  = var.public_subnet_cidr
  private_subnet_cidr = var.private_subnet_cidr
}

module "kms" {
  source = "../../../modules/kms"

  project_name                  = var.project_name
  databricks_account_id         = var.databricks_account_id
  databricks_cross_account_role = module.security.databricks_workspace_role_arn
}

module "storage" {
  source = "../../../modules/storage"

  providers = {
    databricks = databricks.mws
  }

  project_name          = var.project_name
  kms_key_arn           = module.kms.kms_key_arn
  bucket_suffix         = var.bucket_suffix
  databricks_account_id = var.databricks_account_id
}

module "security" {
  source = "../../../modules/security"

  project_name                 = var.project_name
  aws_region                   = var.aws_region
  vpc_id                       = module.networking.vpc_id
  databricks_security_group_id = module.networking.databricks_security_group_id
  kms_key_arn                  = module.kms.kms_key_arn
  data_bucket_arn              = module.storage.data_bucket_arn
  databricks_account_id        = var.databricks_account_id
}

module "endpoints" {
  source = "../../../modules/endpoints"

  project_name    = var.project_name
  vpc_id          = module.networking.vpc_id
  aws_region      = var.aws_region
  vpc_cidr        = var.vpc_cidr
  data_bucket_arn = module.storage.data_bucket_arn

  private_subnet_ids = module.networking.private_subnet_ids

  route_table_ids = [
    module.networking.private_route_table_id
  ]
}

resource "databricks_mws_credentials" "workspace" {
  provider = databricks.mws

  credentials_name = "${var.project_name}-credentials"
  role_arn         = module.security.databricks_workspace_role_arn

  depends_on = [
    time_sleep.wait_for_iam_propagation
  ]
}

resource "databricks_mws_storage_configurations" "workspace" {
  provider = databricks.mws

  account_id                 = var.databricks_account_id
  storage_configuration_name = "${var.project_name}-storage"
  bucket_name                = module.storage.root_bucket_id
}

resource "databricks_mws_networks" "workspace" {
  provider = databricks.mws

  account_id         = var.databricks_account_id
  network_name       = "${var.project_name}-network"
  vpc_id             = module.networking.vpc_id
  subnet_ids         = module.networking.private_subnet_ids
  security_group_ids = [module.networking.databricks_security_group_id]
}

resource "time_sleep" "wait_for_iam_propagation" {
  depends_on = [
    module.security
  ]

  create_duration = "30s"
}

resource "databricks_mws_workspaces" "workspace" {
  provider       = databricks.mws
  account_id     = var.databricks_account_id
  workspace_name = var.project_name
  aws_region     = var.aws_region

  credentials_id           = databricks_mws_credentials.workspace.credentials_id
  storage_configuration_id = databricks_mws_storage_configurations.workspace.storage_configuration_id
  network_id               = databricks_mws_networks.workspace.network_id

  storage_customer_managed_key_id = var.enable_databricks_storage_cmk ? databricks_mws_customer_managed_keys.storage[0].customer_managed_key_id : null

  timeouts {
    create = "30m"
    read   = "10m"
    update = "20m"
  }

  depends_on = [
    time_sleep.wait_for_iam_propagation
  ]
}

#
# The following resource is used to create a customer-managed KMS key in Databricks. 
# It references the KMS key created in the `kms` module and associates it with the Databricks 
# account for use cases such as storage encryption.
# 
# This is toggled by the `enable_databricks_storage_cmk` variable, allowing users to enable or disable 
# the use of a customer-managed key for Databricks workspace storage.
#
resource "databricks_mws_customer_managed_keys" "storage" {
  count = var.enable_databricks_storage_cmk ? 1 : 0

  provider   = databricks.mws
  account_id = var.databricks_account_id

  aws_key_info {
    key_arn   = module.kms.kms_key_arn
    key_alias = "alias/${var.project_name}"
  }

  use_cases = ["STORAGE"]

  depends_on = [
    module.kms
  ]
}

data "databricks_aws_crossaccount_policy" "workspace_expected" {
  provider = databricks.mws

  policy_type = "customer"
}
