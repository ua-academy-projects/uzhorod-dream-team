locals {
  uptime_check_id = one(google_monitoring_uptime_check_config.ui[*].uptime_check_id)

  alert_filters = {
    for k, a in local.alerts : k => join(" ", compact([
      local.filters[a.widget],
      a.check ? "metric.label.check_id=\"${local.uptime_check_id}\"" : ""
    ]))
  }

  alert_aggregations = {
    for k, a in local.alerts : k => {
      period_s = coalesce(try(a.aggregation.period_s, null), local.widgets[a.widget].period_s)
      aligner  = coalesce(try(a.aggregation.aligner, null), local.widgets[a.widget].aligner)
      reducer  = coalesce(try(a.aggregation.reducer, null), local.widgets[a.widget].reducer)
      group_by = coalesce(try(a.aggregation.group_by, null), local.widgets[a.widget].group_by)
    }
  }
}

resource "google_monitoring_alert_policy" "alert" {
  for_each = local.alerts

  project      = var.cfg.google.project_id
  display_name = coalesce(each.value.display_name, "Kyiv Air ${each.key}")
  combiner     = "OR"
  severity     = each.value.severity

  notification_channels = google_monitoring_notification_channel.email[*].name

  conditions {
    display_name = coalesce(each.value.display_name, "Kyiv Air ${each.key}")

    condition_threshold {
      filter                  = local.alert_filters[each.key]
      comparison              = each.value.comparison
      threshold_value         = each.value.threshold
      duration                = "${each.value.duration_s}s"
      evaluation_missing_data = each.value.no_data_ok ? "EVALUATION_MISSING_DATA_INACTIVE" : null

      aggregations {
        alignment_period     = "${local.alert_aggregations[each.key].period_s}s"
        per_series_aligner   = local.alert_aggregations[each.key].aligner
        cross_series_reducer = local.alert_aggregations[each.key].reducer == "REDUCE_NONE" ? null : local.alert_aggregations[each.key].reducer
        group_by_fields      = local.alert_aggregations[each.key].group_by
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

  depends_on = [google_logging_metric.counter]
}
