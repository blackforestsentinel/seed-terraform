variable "name" {
  description = "Projektname aus project.yaml. Kleinbuchstaben, Ziffern und Bindestriche."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,18}[a-z0-9]$", var.name))
    error_message = "name: 3-20 Zeichen, Kleinbuchstaben, Ziffern und Bindestriche, beginnt mit einem Buchstaben."
  }
}

variable "environment" {
  description = "Umgebung, z. B. dev, test oder prod."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,7}$", var.environment))
    error_message = "environment: 2-8 Zeichen, Kleinbuchstaben und Ziffern."
  }
}

variable "location" {
  description = "Azure-Region für Function App, Storage und Monitoring."
  type        = string
  default     = "westeurope"
}

variable "static_web_app_location" {
  description = "Azure-Region der Static Web App. Free-Tier gibt es nur in wenigen Regionen."
  type        = string
  default     = "westeurope"
}

variable "static_web_app_sku" {
  description = "Tarif der Static Web App: Free (höchstens 10 je Subscription), Standard (kostenpflichtig) oder None (Projekt ohne Frontend, nur API)."
  type        = string
  default     = "Free"

  validation {
    condition     = contains(["Free", "Standard", "None"], var.static_web_app_sku)
    error_message = "static_web_app_sku: Free, Standard oder None."
  }
}

variable "custom_domains" {
  description = "Eigene Domains der Static Web App als Hostnamen, z. B. [\"app.example.org\"] oder eine Apex-Domain wie example.org. Free erlaubt 2, Standard 5 Domains. Welche DNS-Einträge nötig sind, steht im Output custom_domain_dns_records."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for d in var.custom_domains : can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?[.])+[a-z][a-z0-9-]*[a-z0-9]$", d))])
    error_message = "custom_domains: Hostnamen in Kleinbuchstaben ohne Schema, Port und Pfad, z. B. app.example.org."
  }

  validation {
    condition     = var.static_web_app_sku != "None" || length(var.custom_domains) == 0
    error_message = "custom_domains: Ohne Static Web App (static_web_app_sku = None) gibt es keine eigenen Domains."
  }
}

variable "runtime_version" {
  description = "Version der dotnet-isolated-Runtime."
  type        = string
  default     = "10.0"
}

variable "instance_memory_mb" {
  description = "Speicher pro Instanz der Flex-Consumption-Function (512, 2048 oder 4096)."
  type        = number
  default     = 2048
}

variable "maximum_instance_count" {
  description = "Obergrenze für das Hochskalieren der Function (1 bis 1000). null gilt als Default, so kann ein Projekt den Wert je Umgebung weglassen."
  type        = number
  default     = 40
  nullable    = false

  validation {
    condition     = var.maximum_instance_count == floor(var.maximum_instance_count) && var.maximum_instance_count >= 1 && var.maximum_instance_count <= 1000
    error_message = "maximum_instance_count: ganze Zahl von 1 bis 1000 (Grenzen von Flex Consumption)."
  }
}

variable "app_settings" {
  description = "Zusätzliche App-Settings der Function, z. B. Auth__TenantId aus dem sso-Modul. Die Grundeinstellungen des Moduls (AzureWebJobsStorage__*, APPLICATIONINSIGHTS_*, AZURE_CLIENT_ID, Seed__Project, Seed__Environment) gehen bei gleichem Namen vor."
  type        = map(string)
  default     = {}
}

variable "cors_allowed_origins" {
  description = "Zusätzliche CORS-Origins, einzeln, z. B. https://www.example.org. Die URL der Static Web App und die eigenen Domains sind immer freigegeben. Ein * und den Origin null lehnt das Modul ab."
  type        = list(string)
  default     = []
  nullable    = false

  # Mit * dürfte jede Website die API aus dem Browser aufrufen und die Antworten lesen. Das gilt
  # auch für Platzhalter wie https://*.example.org: Jede Subdomain wäre freigegeben, auch eine
  # übernommene oder fremd gehostete.
  validation {
    condition     = alltrue([for origin in var.cors_allowed_origins : !strcontains(origin, "*")])
    error_message = "cors_allowed_origins: kein *, sonst dürfte jede Website die API aus dem Browser aufrufen. Origins einzeln angeben, z. B. https://www.example.org."
  }

  # Den Origin null senden Browser für Sandbox-iframes, data:- und file:-Seiten; jede Website kann
  # ihn mit einem solchen iframe erzeugen.
  validation {
    condition     = alltrue([for origin in var.cors_allowed_origins : lower(trimspace(origin)) != "null"])
    error_message = "cors_allowed_origins: kein Origin null, den kann jede Website über ein Sandbox-iframe senden."
  }
}

variable "log_retention_days" {
  description = "Aufbewahrung im Log Analytics Workspace."
  type        = number
  default     = 30
}

variable "log_daily_quota_gb" {
  description = "Tageslimit des Log Analytics Workspace in GB (mindestens 0.023, -1 für kein Limit). Danach nimmt er bis 0 Uhr UTC keine Daten mehr an."
  type        = number
  default     = 1
  nullable    = false

  validation {
    condition     = var.log_daily_quota_gb == -1 || var.log_daily_quota_gb >= 0.023
    error_message = "log_daily_quota_gb: mindestens 0.023 GB oder -1 für kein Limit."
  }
}

variable "tags" {
  description = "Zusätzliche Tags für alle Ressourcen."
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "owner" {
  description = "Besitzer und Ansprechpartner des Projekts, eine E-Mail-Adresse oder ein Verteiler, z. B. team@example.org (im Template owner in project.yaml). Steht als Tag owner an allen Ressourcen und ersetzt einen Tag owner aus tags, gleich wie geschrieben (etwa Owner). null oder leer: kein Tag."
  type        = string
  default     = null

  validation {
    condition     = var.owner == null || var.owner == "" || can(regex("^[^@\\s]+@[^@\\s]+[.][^@\\s]+$", var.owner))
    error_message = "owner: eine E-Mail-Adresse, z. B. team@example.org, oder leer."
  }
}

variable "create_resource_group" {
  description = "Resource Group rg-<name>-<environment> anlegen (Standard). false: Es gibt sie schon, etwa weil das zentrale Scaffold sie vorab anlegt und der Identität des Projekts nur dort Rollen gibt; das Modul liest sie dann nur und ändert weder sie noch ihre Tags. Im Template createResourceGroups in project.yaml."
  type        = bool
  default     = true
  nullable    = false
}
