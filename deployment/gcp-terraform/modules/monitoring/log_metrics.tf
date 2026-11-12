resource "google_logging_metric" "counter" {
  for_each = var.cfg.monitoring.log_metrics

  project     = var.cfg.google.project_id
  name        = each.key
  description = each.value.description
  filter      = join("\n", each.value.filter)

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"

    labels {
      key        = each.value.label_name
      value_type = "INT64"
    }
  }

  label_extractors = {
    (each.value.label_name) = each.value.label_extractor
  }
}
