output "virtual_network_id" {
  value = azurerm_virtual_network.this.id
}

output "network_security_group_id" {
  value = azurerm_network_security_group.this.id
}

output "public_subnet_name" {
  value = azurerm_subnet.public.name
}

output "public_subnet_nsg_association_id" {
  value = azurerm_subnet_network_security_group_association.public.id
}

output "private_subnet_name" {
  value = azurerm_subnet.private.name
}

output "private_subnet_nsg_association_id" {
  value = azurerm_subnet_network_security_group_association.private.id
}
