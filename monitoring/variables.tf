variable "name" {
  description = "Projektname aus project.yaml, wie beim Modul core."
  type        = string
}

variable "environment" {
  description = "Umgebung, z. B. dev oder prod."
  type        = string
}

variable "resource_group_name" {
  description = "Resource Group des Projekts (Output resource_group_name von core). Aktionsgruppe, Alarme und Logic App des Health-Checks liegen darin."
  type        = string
}

variable "resource_group_id" {
  description = "ID der Resource Group (Output resource_group_id von core), Geltungsbereich des Budgets."
  type        = string
}

variable "location" {
  description = "Region von Application Insights (Output location von core). Abfrage-Alarme und Logic App liegen in derselben Region."
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
    # Keine Mindestanzahl: terraform validate prüft die Regel auch bei count = 0, und das Template
    # bindet das Modul ohne Empfänger gar nicht erst ein.
    condition     = alltrue([for e in var.alert_emails : can(regex("^[^@\\s]+@[^@\\s]+[.][^@\\s]+$", e))])
    error_message = "alert_emails: nur gültige E-Mail-Adressen. Ohne Empfänger das Modul per count = 0 weglassen."
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
  description = "URL, die der Health-Check ohne Token abruft und die mit 2xx antworten muss, z. B. \"$${module.core.function_app_url}/api/health\". null: kein Health-Check, kein Health-Alarm."
  type        = string
  default     = null
}

variable "health_check_interval_hours" {
  description = "Abstand der Health-Checks in Stunden, 1 bis 12. Jeder Aufruf startet die Function nach einer Ruhephase und schreibt deren Startmeldungen in die Logs."
  type        = number
  default     = 4
  nullable    = false

  validation {
    condition     = floor(var.health_check_interval_hours) == var.health_check_interval_hours && var.health_check_interval_hours >= 1 && var.health_check_interval_hours <= 12
    error_message = "health_check_interval_hours: ganze Stunden von 1 bis 12."
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
