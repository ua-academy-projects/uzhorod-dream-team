# HTTPS in front of the UI


resource "google_compute_global_address" "ui" {
  name = "crypto-ui"

  depends_on = [google_project_service.this]
}

# Empty until the ui VM exists.
resource "google_compute_instance_group" "ui" {
  name      = "crypto-ui"
  zone      = var.zone
  instances = [for name, vm in google_compute_instance.vm : vm.self_link if name == "ui"]

  named_port {
    name = "http"
    port = 5173
  }
}

resource "google_compute_health_check" "ui" {
  name                = "crypto-ui"
  check_interval_sec  = 10
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3

  http_health_check {
    port         = 5173
    request_path = "/"
  }
}

resource "google_compute_backend_service" "ui" {
  name                  = "crypto-ui"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  protocol              = "HTTP"
  port_name             = "http"
  timeout_sec           = 30
  health_checks         = [google_compute_health_check.ui.id]

  backend {
    group           = google_compute_instance_group.ui.id
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }

  log_config {
    enable      = true
    sample_rate = 1.0
  }
}

resource "google_compute_url_map" "ui" {
  name            = "crypto-ui"
  default_service = google_compute_backend_service.ui.id
}

# Issued once the domain resolves to the load balancer's address.
resource "google_compute_managed_ssl_certificate" "ui" {
  name = "crypto-ui"

  managed {
    domains = [var.domain]
  }
}

resource "google_compute_ssl_policy" "modern" {
  name            = "crypto-modern"
  profile         = "MODERN"
  min_tls_version = "TLS_1_2"
}

resource "google_compute_target_https_proxy" "ui" {
  name             = "crypto-ui"
  url_map          = google_compute_url_map.ui.id
  ssl_certificates = [google_compute_managed_ssl_certificate.ui.id]
  ssl_policy       = google_compute_ssl_policy.modern.id
}

resource "google_compute_global_forwarding_rule" "https" {
  name                  = "crypto-https"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_address            = google_compute_global_address.ui.address
  port_range            = "443"
  target                = google_compute_target_https_proxy.ui.id
}

# Plain HTTP only redirects to HTTPS.
resource "google_compute_url_map" "redirect" {
  name = "crypto-http-redirect"

  default_url_redirect {
    https_redirect         = true
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
    strip_query            = false
  }
}

resource "google_compute_target_http_proxy" "redirect" {
  name    = "crypto-http-redirect"
  url_map = google_compute_url_map.redirect.id
}

resource "google_compute_global_forwarding_rule" "http" {
  name                  = "crypto-http"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_address            = google_compute_global_address.ui.address
  port_range            = "80"
  target                = google_compute_target_http_proxy.redirect.id
}
