terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=2.74.0"
    }
  }
}

provider "azurerm" {
  features {}
}

locals {
  function_app_code_archive_filepath = "./functions.zip"
}

# -------------------------------------------------------------
# Resource Group
# -------------------------------------------------------------
resource "azurerm_resource_group" "main" {
  name     = "rg-${var.identifier}"
  location = var.location
}

# -------------------------------------------------------------
# Storage Account for code
# -------------------------------------------------------------
data "archive_file" "function_app_code" {
  type        = "zip"
  source_dir  = "../functions"
  output_path = local.function_app_code_archive_filepath
}

# -------------------------------------------------------------
# Function App
# -------------------------------------------------------------
resource "azurerm_storage_account" "func" {
  name                     = "st${var.identifier}fc"
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_storage_container" "function_app_code" {
  name                  = "code"
  storage_account_name  = azurerm_storage_account.func.name
  container_access_type = "private"
}

resource "azurerm_storage_blob" "function_app_code" {
  name                   = "${data.archive_file.function_app_code.output_sha}.zip"
  storage_account_name   = azurerm_storage_account.func.name
  storage_container_name = azurerm_storage_container.function_app_code.name
  type                   = "Block"
  source                 = local.function_app_code_archive_filepath
}

data "azurerm_storage_account_blob_container_sas" "function_app_code" {
  connection_string = azurerm_storage_account.func.primary_connection_string
  container_name    = azurerm_storage_container.function_app_code.name
  https_only        = true

  start  = timestamp()
  expiry = timeadd(timestamp(), "10m")

  permissions {
    read   = true
    add    = false
    create = false
    write  = false
    delete = false
    list   = false
  }
}

resource "azurerm_app_service_plan" "main" {
  name                = "plan-${var.identifier}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  kind                = "FunctionApp"
  sku {
    tier = "Dynamic"
    size = "Y1"
  }
}

resource "azurerm_function_app" "main" {
  name                       = "func-${var.identifier}"
  resource_group_name        = azurerm_resource_group.main.name
  location                   = azurerm_resource_group.main.location
  app_service_plan_id        = azurerm_app_service_plan.main.id
  storage_account_name       = azurerm_storage_account.func.name
  storage_account_access_key = azurerm_storage_account.func.primary_access_key
  version                    = "~3"

  app_settings = {
    WEBSITE_RUN_FROM_PACKAGE = "${azurerm_storage_blob.function_app_code.url}${data.azurerm_storage_account_blob_container_sas.function_app_code.sas}"
  }
}

# -------------------------------------------------------------
# Event Grid
# -------------------------------------------------------------
resource "azurerm_storage_account" "eventgrid" {
  name                     = "st${var.identifier}eg"
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_eventgrid_system_topic" "main" {
  name                   = "evgt-${var.identifier}"
  resource_group_name    = azurerm_resource_group.main.name
  location               = azurerm_resource_group.main.location
  source_arm_resource_id = azurerm_storage_account.eventgrid.id
  topic_type             = "Microsoft.Storage.StorageAccounts"
}

resource "azurerm_eventgrid_system_topic_event_subscription" "main" {
  name                = "evgs-${var.identifier}"
  system_topic        = azurerm_eventgrid_system_topic.main.name
  resource_group_name = azurerm_resource_group.main.name
  labels              = []

  azure_function_endpoint {
    function_id                       = "${azurerm_function_app.main.id}/functions/EventGridTrigger1"
    max_events_per_batch              = 1
    preferred_batch_size_in_kilobytes = 64
  }
}
