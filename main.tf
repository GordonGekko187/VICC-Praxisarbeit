# ====================================================================
# INFRASTRUKTUR-DEKLARATION: Azure Web App for Containers
# Projekt: VICC Praxisarbeit
# ====================================================================

# --- 1. Provider & Initialisierung ---
# Festlegen der Provider-Abhängigkeiten und Versionen
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
provider "azurerm" {
  features {}
}

# --- 2. Grundlegende Ressourcen-Verwaltung ---
# Erstellung des logischen Containers für alle nachfolgenden Ressourcen
resource "azurerm_resource_group" "rg" {
  name     = "rg-vicc-praxisarbeit"
  location = "West Europe"
}

# --- 3. Netzwerk-Infrastruktur ---
# Definition des isolierten virtuellen Netzwerks (VNet)
resource "azurerm_virtual_network" "vnet" {
  name                = "vicc-vnet"
  address_space       = ["10.0.0.0/16"] # Gesamter Adressraum des Netzwerks
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

# Spezifisches Subnetz für die App-Service-Integration
resource "azurerm_subnet" "app_subnet" {
  name                 = "snet-app-integration"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"] # Teilbereich des VNets

  # Aktivierung der Service-Delegation: Erlaubt dem App Service exklusiven 
  # Zugriff auf dieses Subnetz für ausgehenden Netzwerkverkehr (Regional VNet Integration).
  delegation {
    name = "delegation-webserverfarms"
    service_delegation {
      name    = "Microsoft.Web/serverFarms"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

# --- 4. Hosting-Umgebung (Compute) ---
# Der App Service Plan definiert die zugrunde liegende Infrastruktur (CPU, RAM, OS)
resource "azurerm_service_plan" "asp" {
  name                = "asp-vicc-service"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  os_type             = "Linux" # Betriebssystem der Hosting-Instanz
  sku_name            = "B1"    # Basic-Tarif (Unterstützt VNet-Integration und Custom Domains)
}

# --- 5. Observability (Monitoring & Logging) ---
# Application Insights Instanz zur Erfassung von Telemetriedaten und App-Performance
resource "azurerm_application_insights" "monitoring" {
  name                = "ins-vicc-app-monitoring"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  application_type    = "web"
}

# --- 6. Applikations-Plattform ---
# Definition der eigentlichen Web App basierend auf einem Docker-Container
resource "azurerm_linux_web_app" "webapp" {
  name                = "webapp-vicc-pa-marc-2026"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  service_plan_id     = azurerm_service_plan.asp.id

  # Verknüpfung mit dem Subnetz für die Netzwerkintegration
  virtual_network_subnet_id = azurerm_subnet.app_subnet.id
  https_only                = true # Erzwingt SSL-Verschlüsselung

  site_config {
    always_on = true # Hält den Container dauerhaft aktiv (verhindert Idle-Shutdown)

    application_stack {
      # Konfiguration des Container-Images aus einer öffentlichen Registry
      docker_image     = "traefik/whoami"
      docker_image_tag = "v1.11"
    }
  }

  # Konfiguration der Umgebungsvariablen (App Settings)
  app_settings = {
    "WEBSITES_PORT" = "80" # Interner Port des Docker-Containers
    
    # Verbindungsparameter für Application Insights
    "APPINSIGHTS_INSTRUMENTATIONKEY"        = azurerm_application_insights.monitoring.instrumentation_key
    "APPLICATIONINSIGHTS_CONNECTION_STRING" = azurerm_application_insights.monitoring.connection_string
  }
}

# --- 7. Bereitstellungs-Outputs ---
# Rückgabewerte nach erfolgreichem Deployment (nützlich für CI/CD oder CLI)

output "app_service_url" {
  description = "Die öffentliche URL, über welche die Web App erreichbar ist."
  value       = "https://${azurerm_linux_web_app.webapp.default_hostname}"
}

output "vnet_id" {
  description = "Die Ressourcen-ID des erstellten virtuellen Netzwerks."
  value       = azurerm_virtual_network.vnet.id
}
