output "instance_name" {
  value = google_sql_database_instance.pg.name
}

# project:region:instance, the argument of cloud-sql-proxy
output "connection_name" {
  value = google_sql_database_instance.pg.connection_name
}

output "private_ip" {
  value = google_sql_database_instance.pg.private_ip_address
}
