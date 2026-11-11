output "connection_name" { value = try(google_sql_database_instance.main[0].connection_name, null) }
output "private_ip" { value = try(google_sql_database_instance.main[0].private_ip_address, null) }
