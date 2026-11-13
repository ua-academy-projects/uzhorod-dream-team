moved {
  from = google_logging_metric.this
  to   = module.logging.google_logging_metric.this
}

moved {
  from = google_monitoring_notification_channel.email
  to   = module.alerts.google_monitoring_notification_channel.email
}

moved {
  from = google_monitoring_alert_policy.this
  to   = module.alerts.google_monitoring_alert_policy.this
}

moved {
  from = google_monitoring_dashboard.this
  to   = module.dashboard.google_monitoring_dashboard.this
}
