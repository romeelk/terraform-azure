terraform {
    required_providers {
        azurerm = {
            source  = "hashicorp/azurerm"
            version = "~> 3.0"
        }
    }
}

provider "azurerm" {
    features {}
}

variable "location" {
    default = "eastus"
}

variable "environment" {
    default = "dev"
}

resource "azurerm_resource_group" "rg" {
    name     = "rg-storage-${var.environment}"
    location = var.location
}

resource "azurerm_storage_account" "storage" {
    name                     = "st${var.environment}${formatdate("MMDD", timestamp())}"
    resource_group_name      = azurerm_resource_group.rg.name
    location                 = azurerm_resource_group.rg.location
    account_tier             = "Standard"
    account_replication_type = "LRS"

    network_rules {
        default_action = "Deny"
    }

    depends_on = [azurerm_resource_group.rg]
}

resource "azurerm_virtual_network" "vnet" {
    name                = "vnet-${var.environment}"
    address_space       = ["10.0.0.0/16"]
    location            = azurerm_resource_group.rg.location
    resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_subnet" "subnet" {
    name                 = "subnet-private-endpoint"
    resource_group_name  = azurerm_resource_group.rg.name
    virtual_network_name = azurerm_virtual_network.vnet.name
    address_prefixes     = ["10.0.1.0/24"]

    
}

resource "azurerm_private_endpoint" "storage_pe" {
    name                = "pe-storage-${var.environment}"
    location            = azurerm_resource_group.rg.location
    resource_group_name = azurerm_resource_group.rg.name
    subnet_id           = azurerm_subnet.subnet.id

    private_service_connection {
        name                           = "psc-storage"
        private_connection_resource_id = azurerm_storage_account.storage.id
        subresource_names              = ["blob"]
        is_manual_connection           = false
    }
}

# variable "ssh_public_key" {
#     description = "Public SSH key for the VM (falls back to ~/.ssh/id_rsa.pub)"
#     default     = file("~/.ssh/id_rsa.pub")
# }

resource "azurerm_subnet" "vm_subnet" {
    name                 = "subnet-vm"
    resource_group_name  = azurerm_resource_group.rg.name
    virtual_network_name = azurerm_virtual_network.vnet.name
    address_prefixes     = ["10.0.2.0/24"]
}

resource "azurerm_public_ip" "vm_pip" {
    name                = "pip-vm-${var.environment}"
    location            = azurerm_resource_group.rg.location
    resource_group_name = azurerm_resource_group.rg.name
    allocation_method   = "Dynamic"
    sku                 = "Basic"
}

resource "azurerm_network_interface" "vm_nic" {
    name                = "nic-vm-${var.environment}"
    location            = azurerm_resource_group.rg.location
    resource_group_name = azurerm_resource_group.rg.name

    ip_configuration {
        name                          = "ipconfig1"
        subnet_id                     = azurerm_subnet.vm_subnet.id
        private_ip_address_allocation = "Dynamic"
        public_ip_address_id          = azurerm_public_ip.vm_pip.id
    }
}

resource "azurerm_linux_virtual_machine" "ubuntu" {
    name                  = "vm-ubuntu-${var.environment}"
    resource_group_name   = azurerm_resource_group.rg.name
    location              = azurerm_resource_group.rg.location
    size                  = "Standard_B1s"
    network_interface_ids = [azurerm_network_interface.vm_nic.id]
    admin_username        = "azureuser"

    admin_ssh_key {
        username   = "azureuser"
        public_key = file("~/.ssh/id_rsa.pub")
    }

    os_disk {
        caching              = "ReadWrite"
        storage_account_type = "Standard_LRS"
        name                 = "osdisk-vm-ubuntu-${var.environment}"
    }

   source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
    }

    tags = {
        environment = var.environment
    }
}

resource "azurerm_private_dns_zone" "blob" {
    name                = "privatelink.blob.core.windows.net"
    resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "blob_vnet_link" {
    name                  = "blob-vnet-link"
    resource_group_name   = azurerm_resource_group.rg.name
    private_dns_zone_name = azurerm_private_dns_zone.blob.name
    virtual_network_id    = azurerm_virtual_network.vnet.id
    registration_enabled  =  true
}

resource "azurerm_private_dns_a_record" "storage_blob" {
    name                = azurerm_storage_account.storage.name
    zone_name           = azurerm_private_dns_zone.blob.name
    resource_group_name = azurerm_resource_group.rg.name
    ttl                 = 300
    records             = [azurerm_private_endpoint.storage_pe.private_service_connection[0].private_ip_address]
}
output "storage_account_id" {
    value = azurerm_storage_account.storage.id
}

output "private_endpoint_id" {
    value = azurerm_private_endpoint.storage_pe.id
}