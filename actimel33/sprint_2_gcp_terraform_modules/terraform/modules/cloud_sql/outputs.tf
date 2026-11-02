output "connection" {
  description = "How the VMs connect: endpoint IP, CA certificate of the instance (public data), database, user and the secret with its password"
  value = {
    host            = google_compute_address.endpoint.address
    ca_cert         = google_sql_database_instance.this.server_ca_cert[0].cert
    name            = google_sql_database.this.name
    user            = google_sql_user.app.name
    password_secret = var.config.password_secret
  }

  # The VMs connect at boot, so they are created only when the endpoint leads to the instance.
  depends_on = [google_compute_forwarding_rule.endpoint]
}
