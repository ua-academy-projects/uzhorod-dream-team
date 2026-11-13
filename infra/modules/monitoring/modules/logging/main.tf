locals {
  metrics = {
    iss_nginx_requests = {
      value_type = "INT64"
      unit       = "1"
      labels = {
        status          = "EXTRACT(jsonPayload.status)"
        upstream_status = "EXTRACT(jsonPayload.upstream_status)"
        class           = "REGEXP_EXTRACT(jsonPayload.status, \"^([0-9])[0-9][0-9]$\")"
      }
      value_extractor = null
    }
    iss_nginx_request_time = {
      value_type = "DISTRIBUTION"
      unit       = "s"
      labels = {
        class = "REGEXP_EXTRACT(jsonPayload.status, \"^([0-9])[0-9][0-9]$\")"
      }
      value_extractor = "EXTRACT(jsonPayload.request_time)"
    }
    iss_positions = {
      value_type = "INT64"
      unit       = "1"
      labels = {
        event     = "REGEXP_EXTRACT(jsonPayload.log, \"position (published|stored)\")"
        container = local.container
      }
      value_extractor = null
    }
    iss_container_errors = {
      value_type = "INT64"
      unit       = "1"
      labels = {
        container = local.container
      }
      value_extractor = null
    }
  }
}

resource "google_logging_metric" "this" {
  for_each = local.metrics

  name             = each.key
  filter           = local.log_filters[each.key]
  label_extractors = each.value.labels
  value_extractor  = each.value.value_extractor

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = each.value.value_type
    unit        = each.value.unit

    dynamic "labels" {
      for_each = each.value.labels
      content {
        key        = labels.key
        value_type = "STRING"
      }
    }
  }

  dynamic "bucket_options" {
    for_each = each.value.value_type == "DISTRIBUTION" ? [1] : []
    content {
      exponential_buckets {
        num_finite_buckets = 20
        growth_factor      = 2
        scale              = 0.001
      }
    }
  }
}
