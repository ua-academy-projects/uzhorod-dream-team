output "private_ip" {
  description = "The instance's address inside our VPC (the only one it has)"
  value       = google_sql_database_instance.pg.private_ip_address
}

output "instance_name" {
  value = google_sql_database_instance.pg.name
}
