# ====================================================================
# INFRASTRUKTUR-DEKLARATION: Azure Web App for Containers
# Projekt: VICC Praxisarbeit
# ====================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    # Workaround für ARM/Provider Eventual Consistency (Wartezeiten zwischen Ressourcen)
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
  }
}

provider "azurerm" {
  features {}
}

# --------------------------------------------------------------------
# 1) Resource Group
# --------------------------------------------------------------------
resource "azurerm_resource_group" "rg" {
  name     = "rg-vicc-praxisarbeit"
  location = "Switzerland North"
}

# --------------------------------------------------------------------
# 2) Netzwerk: VNet + Subnet (Delegation für App Service VNet Integration)
# --------------------------------------------------------------------
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

  delegation {
    name = "delegation-webserverfarms"
    service_delegation {
      name    = "Microsoft.Web/serverFarms"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }

  # Azure/Provider v3 Churn/Propagation: diese Felder wechseln je nach API-Default,
  # und führen sonst gerne zu "inconsistent result after apply".
  lifecycle {
    ignore_changes = [
      private_endpoint_network_policies_enabled,
      private_link_service_network_policies_enabled,
      enforce_private_link_endpoint_network_policies,
      enforce_private_link_service_network_policies,
      default_outbound_access_enabled
    ]
  }
}

# Kurze Wartezeit: Subnet-Delegation/VNet Integration muss im Microsoft.Web Plane "sichtbar" werden
resource "time_sleep" "wait_for_subnet" {
  depends_on      = [azurerm_subnet.app_subnet]
  create_duration = "90s"
}

# --------------------------------------------------------------------
# 3) App Service Plan (Linux)
# --------------------------------------------------------------------
resource "azurerm_service_plan" "asp" {
  name                = "asp-vicc-service"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  os_type             = "Linux"
  sku_name            = "B1"
}

# Wartezeit: App Service Plan wird manchmal direkt nach Create kurz mit 404 gelesen (ARM Propagation)
resource "time_sleep" "wait_for_asp" {
  depends_on      = [azurerm_service_plan.asp]
  create_duration = "60s"
}

# --------------------------------------------------------------------
# 4) Application Insights
# --------------------------------------------------------------------
resource "azurerm_application_insights" "monitoring" {
  name                = "ins-vicc-app-monitoring"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  application_type    = "web"

  # Falls App Insights bereits Workspace-basiert erstellt wurde, darf workspace_id nicht entfernt werden.
  # Das verhindert das permanente "workspace_id can not be removed after set".
  lifecycle {
    ignore_changes = [workspace_id]
  }
}

# --------------------------------------------------------------------
# 5) Linux Web App (Container)
# --------------------------------------------------------------------
resource "azurerm_linux_web_app" "webapp" {
  name                = "webapp-vicc-pa-marc-2026"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  service_plan_id     = azurerm_service_plan.asp.id

  # Hard dependency gegen ARM/Provider 404-Reads (Subnet/ASP sind häufig kurz "unsichtbar")
  depends_on = [
    time_sleep.wait_for_subnet,
    time_sleep.wait_for_asp
  ]

  virtual_network_subnet_id = azurerm_subnet.app_subnet.id
  https_only                = true

  # Verhindert mTLS-Lockout durch komische Provider Defaults
  client_certificate_enabled = false
  client_certificate_mode    = "Optional"

  site_config {
    always_on = true

    application_stack {
      # Container aus Docker Hub (public)
      docker_image_name   = "traefik/whoami:v1.11"
      docker_registry_url = "https://index.docker.io"
    }
  }

  app_settings = {
    "WEBSITES_PORT" = "80"

    "APPINSIGHTS_INSTRUMENTATIONKEY"        = azurerm_application_insights.monitoring.instrumentation_key
    "APPLICATIONINSIGHTS_CONNECTION_STRING" = azurerm_application_insights.monitoring.connection_string
  }

  # Provider v3 macht gerne Read-After-Create (AppSettings) -> 404 für kurze Zeit
  timeouts {
    create = "30m"
    read   = "10m"
    update = "30m"
  }
}

# --------------------------------------------------------------------
# 6) Outputs
# --------------------------------------------------------------------
output "app_service_url" {
  description = "Die öffentliche URL, über welche die Web App erreichbar ist."
  value       = "https://${azurerm_linux_web_app.webapp.default_hostname}"
}

output "vnet_id" {
  description = "Die Ressourcen-ID des erstellten virtuellen Netzwerks."
  value       = azurerm_virtual_network.vnet.id
}
