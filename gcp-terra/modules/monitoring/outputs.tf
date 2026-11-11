output "dashboard_id" { value = try(google_monitoring_dashboard.overview[0].id, null) }
output "notification_channel" { value = try(google_monitoring_notification_channel.email[0].name, null) }
output "uptime_check_id" { value = try(google_monitoring_uptime_check_config.ui[0].uptime_check_id, null) }
