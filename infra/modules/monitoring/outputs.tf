output "dashboard_url" {
  description = "The CityBikes overview dashboard in the cloud's console"
  value       = one(module.gcp[*].dashboard_url)
}
