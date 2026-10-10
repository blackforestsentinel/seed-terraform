variable "name" {
  description = "Projektname aus project.yaml, wie beim Modul core."
  type        = string
}

variable "environment" {
  description = "Umgebung, z. B. dev oder prod."
  type        = string
}

variable "resource_group_name" {
  description = "Resource Group des Projekts (Output resource_group_name von core). Aktionsgruppe, Alarme und Webtest liegen darin."
  type        = string
}

variable "resource_group_id" {
  description = "ID der Resource Group (Output resource_group_id von core), Geltungsbereich des Budgets."
  type        = string
}

variable "location" {
  description = "Region von Application Insights (Output location von core). Abfrage-Alarme und Webtest liegen in derselben Region."
  type        = string
}

variable "application_insights_id" {
  description = "ID von Application Insights (Output application_insights_id von core)."
  type        = string
}

variable "log_analytics_workspace_id" {
  description = "ID des Log Analytics Workspace (Output log_analytics_workspace_id von core), für den Alarm zum Tageslimit."
  type        = string
}

variable "alert_emails" {
  description = "Empfänger der Alarme und Budget-Warnungen: E-Mail-Adressen oder Verteiler. Ohne Empfänger das Modul nicht einbinden."
  type        = list(string)

  validation {
    condition     = length(var.alert_emails) > 0 && alltrue([for e in var.alert_emails : can(regex("^[^@\\s]+@[^@\\s]+[.][^@\\s]+$", e))])
    error_message = "alert_emails: mindestens eine E-Mail-Adresse. Ohne Empfänger das Modul per count = 0 weglassen."
  }
}

variable "exception_threshold" {
  description = "Alarm, sobald in einer Stunde so viele Exceptions auftreten."
  type        = number
  default     = 5
  nullable    = false

  validation {
    condition     = var.exception_threshold >= 1
    error_message = "exception_threshold: mindestens 1."
  }
}

variable "health_check_url" {
  description = "URL, die der Webtest ohne Token abruft und die mit 200 antworten muss, z. B. \"$${module.core.function_app_url}/api/health\". null: kein Webtest, kein Health-Alarm."
  type        = string
  default     = null
}

variable "health_check_frequency" {
  description = "Abstand der Webtest-Läufe in Sekunden: 300, 600 oder 900. Jeder Lauf kostet je Standort rund 0,0006 Euro."
  type        = number
  default     = 900
  nullable    = false

  validation {
    condition     = contains([300, 600, 900], var.health_check_frequency)
    error_message = "health_check_frequency: 300, 600 oder 900."
  }
}

variable "health_check_locations" {
  description = "Standorte des Webtests. Der Alarm kommt erst, wenn alle ausfallen; eine Störung an einem Standort allein ist kein Ausfall der App."
  type        = list(string)
  default     = ["emea-nl-ams-azr", "emea-gb-db3-azr"]
  nullable    = false

  validation {
    condition     = length(var.health_check_locations) > 0
    error_message = "health_check_locations: mindestens ein Standort."
  }
}

variable "budget_amount" {
  description = "Monatsbudget der Resource Group in der Abrechnungswährung. Warnung bei 80 % der tatsächlichen Kosten und wenn die Prognose den Betrag überschreitet. 0: kein Budget."
  type        = number
  default     = 0
  nullable    = false

  validation {
    condition     = var.budget_amount >= 0
    error_message = "budget_amount: 0 (kein Budget) oder ein positiver Betrag."
  }
}

variable "tags" {
  description = "Zusätzliche Tags für alle Ressourcen."
  type        = map(string)
  default     = {}
}
