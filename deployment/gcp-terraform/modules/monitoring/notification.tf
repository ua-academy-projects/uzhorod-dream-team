resource "google_monitoring_notification_channel" "email" {
  count = nonsensitive(var.alert_email != null) ? 1 : 0

  project      = var.cfg.google.project_id
  display_name = "Kyiv Air alerts"
  type         = "email"

  labels = {
    email_address = var.alert_email
  }
}
