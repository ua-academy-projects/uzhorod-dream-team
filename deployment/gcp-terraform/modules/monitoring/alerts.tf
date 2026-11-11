resource "google_monitoring_alert_policy" "this" {
  for_each = local.monitoring.alerts

  project      = var.cfg.google.project_id
  display_name = coalesce(each.value.display_name, "Kyiv Air ${each.key}")
  combiner     = "OR"
  severity     = each.value.severity

  notification_channels = var.notification_channel_ids

  conditions {
    display_name = coalesce(each.value.display_name, "Kyiv Air ${each.key}")

    condition_threshold {
      filter                  = local.filters[each.value.widget]
      comparison              = each.value.comparison
      threshold_value         = each.value.threshold
      duration                = "${each.value.duration_s}s"
      evaluation_missing_data = each.value.no_data_ok ? "EVALUATION_MISSING_DATA_INACTIVE" : null

      aggregations {
        alignment_period     = "${local.widgets[each.value.widget].period_s}s"
        per_series_aligner   = local.widgets[each.value.widget].aligner
        cross_series_reducer = local.widgets[each.value.widget].reducer == "REDUCE_NONE" ? null : local.widgets[each.value.widget].reducer
        group_by_fields      = local.widgets[each.value.widget].group_by
      }

      trigger {
        count = 1
      }
    }
  }

  dynamic "documentation" {
    for_each = each.value.documentation == null ? [] : [each.value.documentation]
    content {
      content   = documentation.value
      mime_type = "text/markdown"
    }
  }
}
