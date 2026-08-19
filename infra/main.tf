locals {
  name_prefix = "${var.project}-${var.environment}"
  tags = {
    environment = var.environment
    managed_by  = "terraform"
    workload    = "static-web-frontdoor"
  }
}

resource "azurerm_resource_group" "RG" {
  name     = "rg-${local.name_prefix}"
  location = var.location
  tags     = local.tags
}

resource "azurerm_static_web_app" "SWA" {
  name                = "swa-${local.name_prefix}"
  resource_group_name = azurerm_resource_group.RG.name
  location            = azurerm_resource_group.RG.location
  sku_tier            = "Standard"
  sku_size            = "Standard"

  # Preview environments are useful for pull-request validation; revisit cost/governance later.
  preview_environments_enabled = true
  tags                         = local.tags
}

resource "azurerm_cdn_frontdoor_profile" "AFD" {
  name                = "afd-${local.name_prefix}"
  resource_group_name = azurerm_resource_group.RG.name
  sku_name            = "Standard_AzureFrontDoor"
  tags                = local.tags
}

resource "azurerm_cdn_frontdoor_endpoint" "this" {
  # Azure requires this to be globally unique. Change project if apply reports a collision.
  name                     = "afd-${var.project}-${var.environment}"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.AFD.id
  tags                     = local.tags
}

resource "azurerm_cdn_frontdoor_origin_group" "AFDOG" {
  name                     = "swa-origin-group"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.AFD.id

  health_probe {
    protocol            = "Https"
    request_type        = "HEAD"
    path                = "/"
    interval_in_seconds = 100
  }

  load_balancing {
    sample_size                        = 4
    successful_samples_required         = 3
    additional_latency_in_milliseconds = 50
  }
}

resource "azurerm_cdn_frontdoor_origin" "swa" {
  name                          = "static-web-app"
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.AFDOG.id
  enabled                       = true
  host_name                     = azurerm_static_web_app.SWA.default_host_name
  origin_host_header            = azurerm_static_web_app.SWA.default_host_name
  http_port                     = 80
  https_port                    = 443
  priority                      = 1
  weight                        = 1000
  certificate_name_check_enabled = true
}

resource "azurerm_cdn_frontdoor_route" "all" {
  name                          = "all-content"
  cdn_frontdoor_endpoint_id     = azurerm_cdn_frontdoor_endpoint.this.id
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.AFDOG.id
  # This is intentionally explicit: it also makes Terraform's creation/destruction ordering unambiguous.
  cdn_frontdoor_origin_ids = [azurerm_cdn_frontdoor_origin.swa.id]

  supported_protocols    = ["Http", "Https"]
  patterns_to_match      = ["/*"]
  forwarding_protocol    = "HttpsOnly"
  https_redirect_enabled = true
  link_to_default_domain = true

  cache {
    query_string_caching_behavior = "UseQueryString"
  }
}