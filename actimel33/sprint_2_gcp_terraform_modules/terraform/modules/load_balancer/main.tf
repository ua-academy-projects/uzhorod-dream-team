# Named port that links the backend service to the port of the instance group.
locals {
  port_name = "http"
}

# External static IP of the site
resource "google_compute_global_address" "lb_public_ip" {
  name = "${var.name}-ip"
}

# The load balancer sends traffic to instance groups only, so the backend VM is put into an unmanaged one.
resource "google_compute_instance_group" "backend" {
  name        = "${var.name}-group"
  zone        = var.zone
  description = "Unmanaged group of instances behind the load balancer"

  instances = [var.instance_id]

  named_port {
    name = local.port_name
    port = var.port
  }
}

resource "google_compute_health_check" "backend" {
  name               = "${var.name}-health-check"
  check_interval_sec = 5
  timeout_sec        = 5

  http_health_check {
    port         = var.port
    request_path = var.health_check_path
  }
}

resource "google_compute_backend_service" "backend" {
  name                  = "${var.name}-backend"
  protocol              = "HTTP"
  port_name             = local.port_name
  load_balancing_scheme = "EXTERNAL_MANAGED"
  timeout_sec           = 30
  health_checks         = [google_compute_health_check.backend.id]

  backend {
    group           = google_compute_instance_group.backend.id
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }
}

# Free Google-managed certificate. It is issued only after the domain points to lb_public_ip.
resource "google_compute_managed_ssl_certificate" "this" {
  name = "${var.name}-cert"

  managed {
    domains = [var.domain_name]
  }
}

# Without a policy Google allows TLS 1.0 and 1.1 with old ciphers.
resource "google_compute_ssl_policy" "this" {
  name            = "${var.name}-ssl-policy"
  profile         = "MODERN"
  min_tls_version = "TLS_1_2"
}

resource "google_compute_url_map" "https" {
  name            = "${var.name}-https-map"
  default_service = google_compute_backend_service.backend.id
}

# HTTPS proxy terminates TLS with the certificate and routes requests by the URL map.
resource "google_compute_target_https_proxy" "https" {
  name             = "${var.name}-https-proxy"
  url_map          = google_compute_url_map.https.id
  ssl_certificates = [google_compute_managed_ssl_certificate.this.id]
  ssl_policy       = google_compute_ssl_policy.this.id
}

resource "google_compute_global_forwarding_rule" "https" {
  name                  = "${var.name}-https-rule"
  ip_address            = google_compute_global_address.lb_public_ip.address
  target                = google_compute_target_https_proxy.https.id
  port_range            = "443"
  load_balancing_scheme = "EXTERNAL_MANAGED"
}

# Plain HTTP only redirects to HTTPS.
resource "google_compute_url_map" "http_redirect" {
  name = "${var.name}-http-redirect-map"

  default_url_redirect {
    https_redirect         = true
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
    strip_query            = false
  }
}

resource "google_compute_target_http_proxy" "http" {
  name    = "${var.name}-http-proxy"
  url_map = google_compute_url_map.http_redirect.id
}

resource "google_compute_global_forwarding_rule" "http" {
  name                  = "${var.name}-http-rule"
  ip_address            = google_compute_global_address.lb_public_ip.address
  target                = google_compute_target_http_proxy.http.id
  port_range            = "80"
  load_balancing_scheme = "EXTERNAL_MANAGED"
}
