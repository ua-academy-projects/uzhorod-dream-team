output "private_ip" {
  value = google_sql_database_instance.db.private_ip_address
}

output "instance" {
  value = google_sql_database_instance.db.name
}
