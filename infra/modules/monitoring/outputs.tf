output "dashboard_url" {
  value = module.dashboard.dashboard_url
}

output "dashboard_json" {
  value = module.dashboard.dashboard_json
}

output "metrics" {
  value = module.logging.metrics
}

output "policies" {
  value = module.alerts.policies
}

output "channels" {
  value = module.alerts.channels
}
