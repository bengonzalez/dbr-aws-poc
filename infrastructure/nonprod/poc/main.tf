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

#
# The following resource is used to create a customer-managed KMS key in Databricks. 
# It references the KMS key created in the `kms` module and associates it with the Databricks 
# account for use cases such as storage encryption.
# 
# THIS WILL BE COMMENTED OUT FOR NOW, AS IT REQUIRES A DATABRICKS ENTERPRISE ACCOUNT TO FUNCTION PROPERLY.
#
# resource "databricks_mws_customer_managed_keys" "storage" {
#   provider   = databricks.mws
#   account_id = var.databricks_account_id

#   aws_key_info {
#     key_arn   = module.kms.kms_key_arn
#     key_alias = "alias/${var.project_name}"
#   }

#   use_cases = ["STORAGE"]

#   depends_on = [
#     module.kms
#   ]
# }
