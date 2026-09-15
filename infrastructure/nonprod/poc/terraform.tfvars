aws_region          = "us-east-1"
project_name        = "databricks-poc"
vpc_cidr            = "10.20.0.0/16"
public_subnet_cidr  = "10.20.1.0/24"
private_subnet_cidr = ["10.20.10.0/24", "10.20.11.0/24"]
bucket_suffix       = "556940913059"

# Set to true to enable Databricks customer-managed key for workspace storage. 
# This will create a KMS key and alias for the Databricks workspace storage bucket.
enable_databricks_storage_cmk = false