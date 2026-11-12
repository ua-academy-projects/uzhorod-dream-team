output "dashboard_url" {
  description = "The CityBikes overview dashboard in the Cloud console"

  value = "https://console.cloud.google.com/monitoring/dashboards/builder/${element(split("/", google_monitoring_dashboard.overview.id), 3)}?project=${var.project_id}"
}
