resource "google_monitoring_notification_channel" "email" {
  for_each = toset(var.config.monitoring.notification_emails)

  display_name = "${local.prefix} ${each.value}"
  type         = "email"
  labels       = { email_address = each.value }
  user_labels  = local.labels
}
