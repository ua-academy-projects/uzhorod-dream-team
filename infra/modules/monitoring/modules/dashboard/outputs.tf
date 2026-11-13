output "dashboard_url" {
  value = "https://console.cloud.google.com/monitoring/dashboards/builder/${element(split("/", google_monitoring_dashboard.this.id), length(split("/", google_monitoring_dashboard.this.id)) - 1)}?project=${local.project}"
}

output "dashboard_json" {
  value = local.dashboard_json
}
