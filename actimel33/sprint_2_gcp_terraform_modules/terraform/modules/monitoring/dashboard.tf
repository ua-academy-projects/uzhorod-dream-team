locals {
  vm_charts = [
    { title = "Requests per minute by response class", x = 0, y = 0, width = 48, plot = "STACKED_BAR", filter = local.requests_filter, aligner = "ALIGN_DELTA", reducer = "REDUCE_SUM", group_by = ["metric.label.response_code_class"], thresholds = [] },
    { title = "CPU utilization by VM", x = 0, y = 16, width = 16, plot = "LINE", filter = local.cpu_filter, aligner = "ALIGN_MEAN", reducer = "REDUCE_MEAN", group_by = ["metadata.system_labels.name"], thresholds = [local.monitoring.cpu_threshold] },
    { title = "Memory used by VM, %", x = 16, y = 16, width = 16, plot = "LINE", filter = local.memory_filter, aligner = "ALIGN_MEAN", reducer = "REDUCE_MEAN", group_by = ["metadata.system_labels.name"], thresholds = [local.monitoring.memory_threshold_percent] },
    { title = "Disk used by VM, %", x = 32, y = 16, width = 16, plot = "LINE", filter = local.disk_filter, aligner = "ALIGN_MEAN", reducer = "REDUCE_MEAN", group_by = ["metadata.system_labels.name", "metric.label.device"], thresholds = [] },
  ]

  cloud_sql_charts = [
    { title = "Cloud SQL CPU utilization", x = 0, y = 32, width = 12, plot = "LINE", filter = "metric.type=\"cloudsql.googleapis.com/database/cpu/utilization\" AND resource.type=\"cloudsql_database\"", aligner = "ALIGN_MEAN", reducer = "REDUCE_MEAN", group_by = ["resource.label.database_id"], thresholds = [] },
    { title = "Cloud SQL memory utilization", x = 12, y = 32, width = 12, plot = "LINE", filter = "metric.type=\"cloudsql.googleapis.com/database/memory/utilization\" AND resource.type=\"cloudsql_database\"", aligner = "ALIGN_MEAN", reducer = "REDUCE_MEAN", group_by = ["resource.label.database_id"], thresholds = [] },
    { title = "Cloud SQL connections", x = 24, y = 32, width = 12, plot = "LINE", filter = "metric.type=\"cloudsql.googleapis.com/database/postgresql/num_backends\" AND resource.type=\"cloudsql_database\"", aligner = "ALIGN_MEAN", reducer = "REDUCE_SUM", group_by = ["resource.label.database_id"], thresholds = [] },
    { title = "Cloud SQL disk utilization", x = 36, y = 32, width = 12, plot = "LINE", filter = "metric.type=\"cloudsql.googleapis.com/database/disk/utilization\" AND resource.type=\"cloudsql_database\"", aligner = "ALIGN_MEAN", reducer = "REDUCE_MEAN", group_by = ["resource.label.database_id"], thresholds = [] },
  ]

  charts = concat(local.vm_charts, var.config.app.database == "cloud_sql" ? local.cloud_sql_charts : [])

  # The API leaves out zeros and empty lists, so the JSON leaves them out too, or every plan shows a change.
  chart_tiles = [
    for chart in local.charts : merge(
      { width = chart.width, height = 16 },
      { for key, value in { xPos = chart.x, yPos = chart.y } : key => value if value > 0 },
      {
        widget = {
          title = chart.title
          xyChart = merge(
            {
              dataSets = [{
                plotType = chart.plot
                timeSeriesQuery = {
                  timeSeriesFilter = {
                    filter = chart.filter
                    aggregation = {
                      alignmentPeriod    = "60s"
                      perSeriesAligner   = chart.aligner
                      crossSeriesReducer = chart.reducer
                      groupByFields      = chart.group_by
                    }
                  }
                }
              }]
            },
            { for key, value in { thresholds = [for t in chart.thresholds : { value = t, label = "alert" }] } : key => value if length(value) > 0 }
          )
        }
      }
    )
  ]
}

resource "google_monitoring_dashboard" "main" {
  dashboard_json = jsonencode({
    displayName = "crypto-price-service"
    mosaicLayout = {
      columns = 48
      tiles   = local.chart_tiles
    }
  })
}
