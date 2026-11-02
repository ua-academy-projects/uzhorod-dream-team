locals {
  port_name = "http"
  vm        = var.instances[var.config.load_balancer.backend]
}

resource "google_compute_global_address" "lb_public_ip" {
  name = "${var.config.load_balancer.name}-ip"
}

resource "google_compute_instance_group" "backend" {
  name        = "${var.config.load_balancer.name}-group"
  zone        = local.vm.zone
  description = "Unmanaged group of instances behind the load balancer"

  instances = [local.vm.id]

  named_port {
    name = local.port_name
    port = local.vm.port
  }
}

resource "google_compute_health_check" "backend" {
  name               = "${var.config.load_balancer.name}-health-check"
  check_interval_sec = 5
  timeout_sec        = 5

  http_health_check {
    port         = local.vm.port
    request_path = var.config.load_balancer.health_check_path
  }
}

resource "google_compute_backend_service" "backend" {
  name                  = "${var.config.load_balancer.name}-backend"
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

resource "google_compute_managed_ssl_certificate" "https" {
  name = "${var.config.load_balancer.name}-cert"

  managed {
    domains = [var.config.load_balancer.domain]
  }
}

resource "google_compute_ssl_policy" "https" {
  name            = "${var.config.load_balancer.name}-ssl-policy"
  profile         = "MODERN"
  min_tls_version = "TLS_1_2"
}

resource "google_compute_url_map" "https" {
  name            = "${var.config.load_balancer.name}-https-map"
  default_service = google_compute_backend_service.backend.id
}


resource "google_compute_target_https_proxy" "https" {
  name             = "${var.config.load_balancer.name}-https-proxy"
  url_map          = google_compute_url_map.https.id
  ssl_certificates = [google_compute_managed_ssl_certificate.https.id]
  ssl_policy       = google_compute_ssl_policy.https.id
}

resource "google_compute_global_forwarding_rule" "https" {
  name                  = "${var.config.load_balancer.name}-https-rule"
  ip_address            = google_compute_global_address.lb_public_ip.address
  target                = google_compute_target_https_proxy.https.id
  port_range            = "443"
  load_balancing_scheme = "EXTERNAL_MANAGED"
}

resource "google_compute_url_map" "http_redirect" {
  name = "${var.config.load_balancer.name}-http-redirect-map"

  default_url_redirect {
    https_redirect         = true
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
    strip_query            = false
  }
}

resource "google_compute_target_http_proxy" "http" {
  name    = "${var.config.load_balancer.name}-http-proxy"
  url_map = google_compute_url_map.http_redirect.id
}

resource "google_compute_global_forwarding_rule" "http" {
  name                  = "${var.config.load_balancer.name}-http-rule"
  ip_address            = google_compute_global_address.lb_public_ip.address
  target                = google_compute_target_http_proxy.http.id
  port_range            = "80"
  load_balancing_scheme = "EXTERNAL_MANAGED"
}
