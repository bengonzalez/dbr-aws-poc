module "networking" {
  source = "../../../modules/networking"

  project_name        = var.project_name
  vpc_cidr            = var.vpc_cidr
  public_subnet_cidr  = var.public_subnet_cidr
  private_subnet_cidr = var.private_subnet_cidr
}

module "kms" {
  source = "../../../modules/kms"

  project_name = var.project_name
}

module "storage" {
  source = "../../../modules/storage"

  project_name  = var.project_name
  kms_key_arn   = module.kms.kms_key_arn
  bucket_suffix = var.bucket_suffix
}

module "security" {
  source = "../../../modules/security"

  project_name    = var.project_name
  kms_key_arn     = module.kms.kms_key_arn
  data_bucket_arn = module.storage.data_bucket_arn
}

module "endpoints" {
  source = "../../../modules/endpoints"

  project_name = var.project_name
  vpc_id       = module.networking.vpc_id

  route_table_ids = [
    module.networking.private_route_table_id
  ]
}