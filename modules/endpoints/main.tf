resource "aws_vpc_endpoint" "s3" {
  vpc_id            = var.vpc_id
  service_name = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = var.route_table_ids

  tags = {
    Name    = "${var.project_name}-s3-endpoint"
    Project = var.project_name
  }
}

resource "aws_security_group" "interface_endpoints" {
  name        = "${var.project_name}-endpoint-sg"
  description = "Security group for interface VPC endpoints"
  vpc_id      = var.vpc_id

  tags = {
    Name    = "${var.project_name}-endpoint-sg"
    Project = var.project_name
  }
}

resource "aws_vpc_security_group_ingress_rule" "interface_endpoints_https" {
  security_group_id = aws_security_group.interface_endpoints.id

  description = "Allow HTTPS access to interface endpoints from the VPC"

  ip_protocol = "tcp"
  from_port   = 443
  to_port     = 443

  cidr_ipv4 = var.vpc_cidr
}

resource "aws_vpc_endpoint" "kms" {
  vpc_id = var.vpc_id

  service_name = "com.amazonaws.${var.aws_region}.kms"
  vpc_endpoint_type = "Interface"
  subnet_ids = var.private_subnet_ids

  security_group_ids = [
    aws_security_group.interface_endpoints.id
  ]

  private_dns_enabled = true

  tags = {
    Name    = "${var.project_name}-kms-endpoint"
    Project = var.project_name
  }
}