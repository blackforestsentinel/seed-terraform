variable "name" {
  description = "Projektname aus project.yaml, wie im Modul core."
  type        = string
}

variable "environment" {
  description = "Umgebung, z. B. dev, test oder prod."
  type        = string
}

variable "resource_group_name" {
  description = "Resource Group des Projekts (Output resource_group_name von core)."
  type        = string
}

variable "location" {
  description = "Azure-Region (Output location von core)."
  type        = string
}

variable "function_identity_principal_id" {
  description = "Principal-ID der Managed Identity der Function (Output function_identity_principal_id von core); sie bekommt die Datenrollen."
  type        = string
}

variable "function_identity_client_id" {
  description = "Client-ID der Managed Identity der Function (Output function_identity_client_id von core); steht in den App-Settings der Verbindung."
  type        = string
}

variable "tables" {
  description = "Tabellen, z. B. [\"jobs\"]. Buchstaben und Ziffern, 3-63 Zeichen, beginnt mit einem Buchstaben."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for t in var.tables : can(regex("^[A-Za-z][A-Za-z0-9]{2,62}$", t)) && lower(t) != "tables"])
    error_message = "tables: Buchstaben und Ziffern, 3-63 Zeichen, beginnt mit einem Buchstaben; \"tables\" ist reserviert."
  }
}

variable "containers" {
  description = "Blob-Container, z. B. [\"uploads\"]. Kleinbuchstaben, Ziffern und einzelne Bindestriche, 3-63 Zeichen."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.containers : can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", c)) && !strcontains(c, "--")])
    error_message = "containers: Kleinbuchstaben, Ziffern und einzelne Bindestriche, 3-63 Zeichen, Anfang und Ende kein Bindestrich."
  }
}

variable "queues" {
  description = "Queues, z. B. [\"jobs\"]. Wie Container, höchstens 56 Zeichen, damit die Poison-Queue <name>-poison noch passt."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for q in var.queues : can(regex("^[a-z0-9][a-z0-9-]{1,54}[a-z0-9]$", q)) && !strcontains(q, "--") && !endswith(q, "-poison")])
    error_message = "queues: Kleinbuchstaben, Ziffern und einzelne Bindestriche, 3-56 Zeichen; <name>-poison legt der Functions-Host selbst an."
  }
}

variable "deletion_lock" {
  description = "Löschsperre (CanNotDelete) auf dem Storage Account. Sie verhindert das Löschen im Portal, per CLI und mit der Resource Group und wirkt auch auf Tabellen, Queues und Container: Ein Apply, der eine davon entfernt, scheitert. Für gewolltes Löschen setzt die Pipeline allow_data_deletion (Bestätigung im Lauf)."
  type        = bool
  default     = true
  nullable    = false
}

variable "allow_data_deletion" {
  description = "Löschsperre für diesen Lauf aufheben, damit ein bestätigter Plan Daten löschen kann. Setzt die Pipeline nur bei confirmDataDeletion (TF_VAR_allow_data_deletion); der nächste Lauf ohne Bestätigung setzt die Sperre wieder."
  type        = bool
  default     = false
  nullable    = false
}

variable "replication_type" {
  description = "Replikation des Storage Accounts: LRS (Standard), ZRS, GRS, GZRS, RAGRS oder RAGZRS."
  type        = string
  default     = "LRS"

  validation {
    condition     = contains(["LRS", "ZRS", "GRS", "GZRS", "RAGRS", "RAGZRS"], var.replication_type)
    error_message = "replication_type: LRS, ZRS, GRS, GZRS, RAGRS oder RAGZRS."
  }
}

variable "blob_versioning_enabled" {
  description = "Blob-Versionierung: Überschreiben und Löschen hinterlassen eine vorherige Version, die blob_version_retention_days lang erhalten bleibt."
  type        = bool
  default     = true
}

variable "blob_version_retention_days" {
  description = "Nach so vielen Tagen ab ihrer Entstehung löscht eine Lifecycle-Regel vorherige Versionen (und Snapshots). Danach greift noch blob_soft_delete_days."
  type        = number
  default     = 7

  validation {
    condition     = var.blob_version_retention_days >= 1 && var.blob_version_retention_days <= 3650
    error_message = "blob_version_retention_days: 1 bis 3650."
  }
}

variable "blob_soft_delete_days" {
  description = "Soft Delete für Blobs und Versionen: So lange bleiben gelöschte Daten wiederherstellbar."
  type        = number
  default     = 7

  validation {
    condition     = var.blob_soft_delete_days >= 1 && var.blob_soft_delete_days <= 365
    error_message = "blob_soft_delete_days: 1 bis 365."
  }
}

variable "container_soft_delete_days" {
  description = "Soft Delete für Container: So lange bleibt ein gelöschter Container samt Inhalt wiederherstellbar."
  type        = number
  default     = 7

  validation {
    condition     = var.container_soft_delete_days >= 1 && var.container_soft_delete_days <= 365
    error_message = "container_soft_delete_days: 1 bis 365."
  }
}

variable "lifecycle_rules" {
  description = <<-EOT
    Lifecycle-Regeln für Blobs (Block-Blobs), z. B. Aufbewahrungsfristen nach DSGVO:
    name, prefixes (Präfixe mit Container, z. B. ["uploads/"], leer = alle Blobs),
    cool_after_days (nach Tagen seit der letzten Änderung in den Tarif Cool),
    delete_after_days (nach Tagen seit der letzten Änderung löschen).
  EOT
  type = list(object({
    name              = string
    prefixes          = optional(list(string), [])
    cool_after_days   = optional(number)
    delete_after_days = optional(number)
  }))
  default = []

  validation {
    condition     = alltrue([for r in var.lifecycle_rules : can(regex("^[A-Za-z0-9-]{1,200}$", r.name)) && !startswith(r.name, "seed-")])
    error_message = "lifecycle_rules: name aus Buchstaben, Ziffern und Bindestrichen; das Präfix seed- ist für Regeln des Moduls reserviert."
  }

  validation {
    condition     = length(distinct([for r in var.lifecycle_rules : r.name])) == length(var.lifecycle_rules)
    error_message = "lifecycle_rules: Namen müssen eindeutig sein."
  }

  validation {
    condition     = alltrue([for r in var.lifecycle_rules : r.cool_after_days != null || r.delete_after_days != null])
    error_message = "lifecycle_rules: Jede Regel braucht cool_after_days oder delete_after_days."
  }

  validation {
    condition     = alltrue([for r in var.lifecycle_rules : r.cool_after_days == null || r.delete_after_days == null || try(r.delete_after_days > r.cool_after_days, false)])
    error_message = "lifecycle_rules: delete_after_days muss größer als cool_after_days sein."
  }

  validation {
    condition     = alltrue(flatten([for r in var.lifecycle_rules : [for p in r.prefixes : can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9](/.*)?$", p))]]))
    error_message = "lifecycle_rules: prefixes beginnen mit dem Container, z. B. \"uploads/\" oder \"uploads/archiv/\"."
  }
}

variable "tags" {
  description = "Zusätzliche Tags für den Storage Account."
  type        = map(string)
  default     = {}
}
