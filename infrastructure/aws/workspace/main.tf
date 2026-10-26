module "deployment" {
  source = "../../../modules/aws/workspace-deployment"

  providers = {
    databricks.mws = databricks.mws
  }

  databricks_account_id = var.databricks_account_id

  workspace   = var.workspace
  cloud       = var.cloud
  application = var.application
  ownership   = var.ownership
  platform    = var.platform
  network     = var.network
  data        = var.data
  encryption  = var.encryption
  governance  = var.governance
  compute     = var.compute
  logging     = var.logging
  validation  = var.validation
  tags        = var.tags

  vpc_ownership_override            = var.vpc_ownership_override
  routing_ownership_override        = var.routing_ownership_override
  security_group_ownership_override = var.security_group_ownership_override
  endpoints_ownership_override      = var.endpoints_ownership_override
  vpc_cidr                          = var.vpc_cidr
  existing_security_group_id        = var.existing_security_group_id
  existing_subnet_ids               = var.existing_subnet_ids
  existing_endpoint_subnet_ids      = var.existing_endpoint_subnet_ids
  existing_s3_gateway_endpoint_id   = var.existing_s3_gateway_endpoint_id
  existing_sts_endpoint_id          = var.existing_sts_endpoint_id
  existing_kms_endpoint_id          = var.existing_kms_endpoint_id
  privatelink_enabled_override      = var.privatelink_enabled_override
  nat_enabled_override              = var.nat_enabled_override
  nat_subnet_cidr                   = var.nat_subnet_cidr

  existing_workspace_storage_key_arn   = var.existing_workspace_storage_key_arn
  existing_workspace_storage_key_alias = var.existing_workspace_storage_key_alias
  existing_managed_services_key_arn    = var.existing_managed_services_key_arn
  existing_managed_services_key_alias  = var.existing_managed_services_key_alias
  existing_metastore_id                = var.existing_metastore_id
  catalog_admin_principal              = var.catalog_admin_principal
  compliance_standards                 = var.compliance_standards
  network_policy_id                    = var.network_policy_id
}
