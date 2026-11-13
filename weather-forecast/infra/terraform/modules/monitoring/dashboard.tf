locals {
  alert_policies = concat(
    values(google_monitoring_alert_policy.vm_metric),
    values(google_monitoring_alert_policy.error_share),
    values(google_monitoring_alert_policy.uptime),
  )

  vm_thresholds = { for alert in values(local.vm_metric_alerts) : alert.metric => alert.above * local.vm_metrics[alert.metric].scale }

  vm_charts = [
    for name, metric in local.vm_metrics : {
      title = "${metric.title}, %, 1 min mean"
      xyChart = {
        dataSets = [{
          plotType   = "LINE"
          targetAxis = "Y1"
          timeSeriesQuery = {
            timeSeriesFilter = {
              filter      = metric.filter
              aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_MEAN", crossSeriesReducer = "REDUCE_MEAN", groupByFields = [metric.group_by] }
            }
          }
        }]
        thresholds = [for value in [lookup(local.vm_thresholds, name, null)] : { value = value } if value != null]
        yAxis      = { label = "%", scale = "LINEAR" }
      }
    }
  ]
}

resource "google_monitoring_dashboard" "overview" {
  dashboard_json = jsonencode({
    displayName = "${local.prefix} overview"
    gridLayout = {
      columns = 3
      widgets = concat(
        [
          {
            title = "Requests per second, 1 min"
            scorecard = {
              timeSeriesQuery = {
                timeSeriesFilter = {
                  filter      = local.responses_filter
                  aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_RATE", crossSeriesReducer = "REDUCE_SUM" }
                }
              }
              sparkChartView = { sparkChartType = "SPARK_LINE" }
            }
          },
          {
            title = "5xx share of requests, 5 min"
            scorecard = {
              timeSeriesQuery = {
                timeSeriesFilterRatio = {
                  numerator   = { filter = local.errors_filter, aggregation = { alignmentPeriod = "300s", perSeriesAligner = "ALIGN_DELTA", crossSeriesReducer = "REDUCE_SUM" } }
                  denominator = { filter = local.responses_filter, aggregation = { alignmentPeriod = "300s", perSeriesAligner = "ALIGN_DELTA", crossSeriesReducer = "REDUCE_SUM" } }
                }
              }
              thresholds = [for alert in values(local.error_share_alerts) : { value = alert.above / 100, color = "RED", direction = "ABOVE" }]
            }
          },
          {
            title = "Uptime checks passed, 5 min"
            xyChart = {
              dataSets = [{
                plotType   = "LINE"
                targetAxis = "Y1"
                timeSeriesQuery = {
                  timeSeriesFilter = {
                    filter      = local.uptime_filter
                    aggregation = { alignmentPeriod = "300s", perSeriesAligner = "ALIGN_FRACTION_TRUE", crossSeriesReducer = "REDUCE_MEAN", groupByFields = ["metric.label.check_id"] }
                  }
                }
              }]
              yAxis = { label = "share of checks", scale = "LINEAR" }
            }
          },
          {
            title = "Requests per second by status class, 1 min"
            xyChart = {
              dataSets = [{
                plotType   = "STACKED_BAR"
                targetAxis = "Y1"
                timeSeriesQuery = {
                  timeSeriesFilter = {
                    filter      = local.responses_filter
                    aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_RATE", crossSeriesReducer = "REDUCE_SUM", groupByFields = ["metric.label.status_class"] }
                  }
                }
              }]
              yAxis = { label = "requests/s", scale = "LINEAR" }
            }
          },
        ],
        local.vm_charts,
        [
          {
            title = "nginx 5xx responses"
            logsPanel = {
              filter        = "log_id(\"nginx_access\") AND httpRequest.status>=500"
              resourceNames = ["projects/${data.google_client_config.current.project}"]
            }
          },
          {
            title = "Incidents"
            incidentList = {
              policyNames = [for policy in local.alert_policies : regex("alertPolicies/.+", policy.name)]
            }
          },
        ],
      )
    }
  })
}
