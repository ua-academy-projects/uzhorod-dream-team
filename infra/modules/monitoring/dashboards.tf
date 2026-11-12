locals {
  by_vm = ["metadata.system_labels.\"name\""]

  cpu_alert_line = 0.8


  queries = {
    rps             = { filter = local.log_filter.requests, period = 60, aligner = "ALIGN_RATE", reducer = "REDUCE_SUM" }
    rps_by_status   = { filter = local.log_filter.requests, period = 60, aligner = "ALIGN_RATE", reducer = "REDUCE_SUM", group_by = ["metric.label.status_class"] }
    status_per_hour = { filter = local.log_filter.requests, period = 3600, aligner = "ALIGN_SUM", reducer = "REDUCE_SUM", group_by = ["metric.label.status_class"] }
    route_per_hour  = { filter = local.log_filter.requests, period = 3600, aligner = "ALIGN_SUM", reducer = "REDUCE_SUM", group_by = ["metric.label.route"] }
    latency_p95     = { filter = local.log_filter.latency, period = 300, aligner = "ALIGN_PERCENTILE_95" }
    uptime          = { filter = local.metric_filter.uptime, period = 300, aligner = "ALIGN_FRACTION_TRUE", reducer = "REDUCE_MEAN", unit = "10^2.%" }
    cpu             = { filter = local.metric_filter.cpu, period = 60, aligner = "ALIGN_MEAN", reducer = "REDUCE_MEAN", group_by = local.by_vm }
    disk            = { filter = local.metric_filter.disk, period = 300, aligner = "ALIGN_MEAN", reducer = "REDUCE_MEAN", group_by = local.by_vm }
    error_rate      = { filter = local.log_filter.request_errors, period = 300, aligner = "ALIGN_DELTA", reducer = "REDUCE_MEAN", unit = "10^2.%" }
    free_bikes      = { filter = local.log_filter.free_bikes, period = 60, aligner = "ALIGN_DELTA", reducer = "REDUCE_MEAN" }
  }

  query = { for name, q in local.queries : name => merge({ reducer = null, group_by = null, unit = null }, q) }

  tsq = {
    for name, q in local.query : name => merge(
      {
        timeSeriesFilter = {
          filter = q.filter
          aggregation = { for k, v in {
            alignmentPeriod    = "${q.period}s"
            perSeriesAligner   = q.aligner
            crossSeriesReducer = q.reducer
            groupByFields      = q.group_by
          } : k => v if v != null }
        }
      },
      { for k, v in { unitOverride = q.unit } : k => v if v != null },
    )
  }



    alert_line = { label = "alert" }

  widget = {
    rps_now        = { title = "Requests/s", scorecard = { timeSeriesQuery = local.tsq.rps, sparkChartView = { sparkChartType = "SPARK_LINE" } } }
    error_rate_now = { title = "Error rate (5xx)", scorecard = { timeSeriesQuery = local.tsq.error_rate, sparkChartView = { sparkChartType = "SPARK_LINE" } } }
    latency_now    = { title = "Latency p95", scorecard = { timeSeriesQuery = local.tsq.latency_p95, sparkChartView = { sparkChartType = "SPARK_LINE" } } }
    uptime_now     = { title = "Uptime (checks)", scorecard = { timeSeriesQuery = local.tsq.uptime, sparkChartView = { sparkChartType = "SPARK_LINE" } } }
    free_bikes_now = { title = "Free bikes", scorecard = { timeSeriesQuery = local.tsq.free_bikes, sparkChartView = { sparkChartType = "SPARK_LINE" } } }

    rps_by_status = {
      title   = "Requests/s by status"
      xyChart = { dataSets = [{ timeSeriesQuery = local.tsq.rps_by_status, plotType = "STACKED_BAR" }] }
    }
    error_rate = {
      title = "5xx / all requests"
      xyChart = {
        dataSets   = [{ timeSeriesQuery = local.tsq.error_rate, plotType = "LINE" }]
        thresholds = [merge(local.alert_line, { value = local.alerts.error_rate_percent.threshold / 100 })]
      }
    }
    status_share = {
      title    = "Status share, per hour"
      pieChart = { chartType = "DONUT", dataSets = [{ timeSeriesQuery = local.tsq.status_per_hour }] }
    }


    latency = {
      title = "Latency p95"
      xyChart = {
        dataSets   = [{ timeSeriesQuery = local.tsq.latency_p95, plotType = "LINE" }]
        thresholds = [merge(local.alert_line, { value = local.alerts.latency_p95_seconds.threshold })]
      }
    }
    cpu = {
      title = "CPU by VM"
      xyChart = {
        dataSets   = [{ timeSeriesQuery = local.tsq.cpu, plotType = "LINE" }]
        thresholds = [merge(local.alert_line, { value = local.cpu_alert_line })]
      }
    }
    disk = {
      title = "Root disk by VM, %"
      xyChart = {
        dataSets   = [{ timeSeriesQuery = local.tsq.disk, plotType = "LINE" }]
        thresholds = [merge(local.alert_line, { value = local.alerts.disk_percent.threshold })]
      }
    }
    route_share = {
      title    = "Requests by endpoint, per hour"
      pieChart = { chartType = "DONUT", dataSets = [{ timeSeriesQuery = local.tsq.route_per_hour }] }
    }
  }

  rows = [
    { height = 10, widths = [10, 10, 10, 9, 9], widgets = [local.widget.rps_now, local.widget.error_rate_now, local.widget.latency_now, local.widget.uptime_now, local.widget.free_bikes_now] },
    { height = 16, widths = [24, 12, 12], widgets = [local.widget.rps_by_status, local.widget.error_rate, local.widget.status_share] },
    { height = 16, widths = [12, 12, 12, 12], widgets = [local.widget.latency, local.widget.cpu, local.widget.disk, local.widget.route_share] },
  ]

  tiles = flatten([
    for r, row in local.rows : [
      for c, widget in row.widgets : merge(
        { width = row.widths[c], height = row.height, widget = widget },
        { for axis, position in {
          xPos = sum(concat([0], slice(row.widths, 0, c)))
          yPos = sum(concat([0], [for i, above in local.rows : above.height if i < r]))
        } : axis => position if position > 0 },
      )
    ]
  ])
}

resource "google_monitoring_dashboard" "overview" {
  dashboard_json = jsonencode({
    displayName  = "CityBikes overview"
    mosaicLayout = { columns = 48, tiles = local.tiles }
  })
}
