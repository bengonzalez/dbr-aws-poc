output "virtual_network_id" {
  value = local.vnet_id
}

output "network_security_group_id" {
  value = local.create_subnets ? azurerm_network_security_group.this[0].id : data.azurerm_subnet.existing_public[0].network_security_group_id
}

output "public_subnet_name" {
  value = local.create_subnets ? azurerm_subnet.public[0].name : data.azurerm_subnet.existing_public[0].name
}

# An azurerm_subnet_network_security_group_association's id is the subnet's
# own id, so an adopted subnet's id stands in for it directly.
output "public_subnet_nsg_association_id" {
  value = local.create_subnets ? azurerm_subnet_network_security_group_association.public[0].id : data.azurerm_subnet.existing_public[0].id
}

output "private_subnet_name" {
  value = local.create_subnets ? azurerm_subnet.private[0].name : data.azurerm_subnet.existing_private[0].name
}

output "private_subnet_nsg_association_id" {
  value = local.create_subnets ? azurerm_subnet_network_security_group_association.private[0].id : data.azurerm_subnet.existing_private[0].id
}

output "private_endpoint_subnet_id" {
  value = try(azurerm_subnet.private_endpoints[0].id, null)
}
