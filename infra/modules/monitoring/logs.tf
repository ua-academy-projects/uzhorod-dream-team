locals {

  docker_logs       = "logName=\"projects/${var.project_id}/logs/gcplogs-docker-driver\""
  ui_requests       = "${local.docker_logs} AND jsonPayload.container.name:\"ui\" AND jsonPayload.message=~\"^status=\""
  history_snapshots = "${local.docker_logs} AND jsonPayload.container.name:\"history\" AND jsonPayload.message=~\"stored snapshot\""


  log_filter = {
    requests       = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.requests.name}\" AND resource.type=\"gce_instance\""
    request_errors = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.request_errors.name}\" AND resource.type=\"gce_instance\""
    latency        = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.latency.name}\" AND resource.type=\"gce_instance\""
    snapshots      = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.snapshots_stored.name}\" AND resource.type=\"gce_instance\""
    free_bikes     = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.free_bikes.name}\" AND resource.type=\"gce_instance\""
  }
}



resource "google_logging_metric" "requests" {
  name        = "${var.config.prefix}/requests"
  description = "Requests served by nginx in ui, by status class and route"
  filter      = local.ui_requests

  label_extractors = {
    status_class = "REGEXP_EXTRACT(jsonPayload.message, \"class=([1-5]xx)\")"
    route        = "REGEXP_EXTRACT(jsonPayload.message, \"route=([^ ]+)\")"
  }

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
    labels {
      key        = "status_class"
      value_type = "STRING"
    }
    labels {
      key        = "route"
      value_type = "STRING"
    }
  }
}

resource "google_logging_metric" "request_errors" {
  name            = "${var.config.prefix}/request_errors"
  description     = "Every request: 0 = fine, 1 = 5xx. Its mean is the error rate"
  filter          = local.ui_requests
  value_extractor = "REGEXP_EXTRACT(jsonPayload.message, \"err=([01])\")"

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "DISTRIBUTION"
    unit        = "1"
  }

  bucket_options {
    explicit_buckets {
      bounds = [1]
    }
  }
}

resource "google_logging_metric" "latency" {
  name            = "${var.config.prefix}/latency"
  description     = "Time of every request to nginx in ui"
  filter          = local.ui_requests
  value_extractor = "REGEXP_EXTRACT(jsonPayload.message, \" rt=([0-9.]+)\")"

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "DISTRIBUTION"
    unit        = "s"
  }

  bucket_options {
    exponential_buckets {
      scale              = 0.001 
      growth_factor      = 1.15 
      num_finite_buckets = 80   
    }
  }
}

resource "google_logging_metric" "snapshots_stored" {
  name        = "${var.config.prefix}/snapshots_stored"
  description = "Snapshots stored by history"
  filter      = local.history_snapshots

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_logging_metric" "free_bikes" {
  name            = "${var.config.prefix}/free_bikes"
  description     = "Free bikes in every stored snapshot"
  filter          = local.history_snapshots
  value_extractor = "REGEXP_EXTRACT(jsonPayload.message, \"([0-9]+) bikes\")"

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "DISTRIBUTION"
    unit        = "1"
  }

  bucket_options {
    linear_buckets {
      offset             = 0
      width              = 10  
      num_finite_buckets = 150
    }
  }
}
