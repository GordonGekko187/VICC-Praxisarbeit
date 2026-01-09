# ====================================================================
# INFRASTRUKTUR-DEKLARATION: Azure Web App for Containers
# Projekt: VICC Praxisarbeit
# ====================================================================

# --- 1. Provider & Initialisierung ---
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

# Konfiguration des Azure Resource Manager Providers
# resource_provider_registrations = "core" verhindert, dass Terraform versucht,
# "alle" Provider im Abo zu registrieren (häufiger Grund für Plan-Hänger/Fehler in
# eingeschränkten Subscriptions).
provider "azurerm" {
  features {}
  resource_provider_registrations = "core"
}

# --- 2. Grundlegende Ressourcen-Verwaltung ---
resource "azurerm_resource_group" "rg" {
  name     = "rg-vicc-praxisarbeit"
  location = "West Europe"
}

# --- 3. Netzwerk-Infrastruktur ---
resource "azurerm_virtual_network" "vnet" {
  name                = "vicc-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_subnet" "app_subnet" {
  name                 = "snet-app-integration"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]

  # Service Delegation: App Service (serverFarms) darf dieses Subnetz für
  # die Regional VNet Integration verwenden (Outbound).
  delegation {
    name = "delegation-webserverfarms"
    service_delegation {
      name    = "Microsoft.Web/serverFarms"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

# --- 4. Hosting-Umgebung (Compute) ---
resource "azurerm_service_plan" "asp" {
  name                = "asp-vicc-service"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  os_type             = "Linux"
  sku_name            = "B1"
}

# --- 5. Observability (Monitoring & Logging) ---
resource "azurerm_application_insights" "monitoring" {
  name                = "ins-vicc-app-monitoring"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  application_type    = "web"
}

# --- 6. Applikations-Plattform ---
resource "azurerm_linux_web_app" "webapp" {
  name                = "webapp-vicc-pa-marc-2026"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  service_plan_id     = azurerm_service_plan.asp.id

  # Verknüpfung mit dem Subnetz für die Netzwerkintegration (Outbound)
  virtual_network_subnet_id = azurerm_subnet.app_subnet.id

  https_only = true

  site_config {
    always_on = true

    application_stack {
      # FIX: docker_image / docker_image_tag sind deprecated -> docker_image_name verwenden
      # Öffentliche Registry (Docker Hub)
      docker_image_name   = "traefik/whoami:v1.11"
      docker_registry_url = "https://index.docker.io"
    }
  }

  app_settings = {
    "WEBSITES_PORT" = "80"

    # Application Insights
    "APPINSIGHTS_INSTRUMENTATIONKEY"        = azurerm_application_insights.monitoring.instrumentation_key
    "APPLICATIONINSIGHTS_CONNECTION_STRING" = azurerm_application_insights.monitoring.connection_string
  }
}

# --- 7. Bereitstellungs-Outputs ---
output "app_service_url" {
  description = "Die öffentliche URL, über welche die Web App erreichbar ist."
  value       = "https://${azurerm_linux_web_app.webapp.default_hostname}"
}

output "vnet_id" {
  description = "Die Ressourcen-ID des erstellten virtuellen Netzwerks."
  value       = azurerm_virtual_network.vnet.id
}
