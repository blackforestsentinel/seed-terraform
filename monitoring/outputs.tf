output "action_group_id" {
  description = "ID der Aktionsgruppe, für eigene Alarme des Projekts an dieselben Empfänger."
  value       = azurerm_monitor_action_group.this.id
}
