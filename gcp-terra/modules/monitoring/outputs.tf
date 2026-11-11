output "dashboard_id" { value = google_monitoring_dashboard.overview.id }
output "notification_channel" { value = google_monitoring_notification_channel.email.name }
output "uptime_check_id" { value = google_monitoring_uptime_check_config.ui.uptime_check_id }
