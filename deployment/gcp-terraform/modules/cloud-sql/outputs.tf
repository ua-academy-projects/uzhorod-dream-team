output "connection_name" {
  value = google_sql_database_instance.main.connection_name
}
output "dns_name" {
  value = google_sql_database_instance.main.dns_name
}
output "endpoint_ip" {
  value = google_compute_address.endpoint.address
}
