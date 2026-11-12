locals {
  monitoring = var.cfg.monitoring
  grid_unit  = 4

  widgets = { for w in local.monitoring.widgets : w.id => w if w.enabled }
  alerts  = { for k, a in local.monitoring.alerts : k => a if contains(keys(local.widgets), a.widget) }

  filters = {
    for id, w in local.widgets : id => join(" ", concat(
      ["metric.type=\"${w.metric_type}\"", "resource.type=\"${w.resource_type}\""],
      w.filters
    ))
  }

  aggregations = {
    for id, w in local.widgets : id => merge(
      {
        alignmentPeriod  = "${w.period_s}s"
        perSeriesAligner = w.aligner
      },
      w.reducer == "REDUCE_NONE" ? {} : { crossSeriesReducer = w.reducer },
      length(w.group_by) == 0 ? {} : { groupByFields = w.group_by }
    )
  }

  queries = {
    for id, w in local.widgets : id => merge(
      {
        timeSeriesFilter = merge(
          {
            filter      = local.filters[id]
            aggregation = local.aggregations[id]
          },
          w.top_series == null ? {} : {
            pickTimeSeriesFilter = {
              rankingMethod = "METHOD_MEAN"
              numTimeSeries = w.top_series
              direction     = "TOP"
            }
          }
        )
      },
      w.unit == null ? {} : { unitOverride = w.unit }
    )
  }

  chart_widgets = {
    for id, w in local.widgets : id => {
      title = w.title
      xyChart = {
        dataSets = [merge(
          {
            timeSeriesQuery    = local.queries[id]
            plotType           = w.plot_type
            minAlignmentPeriod = "${w.period_s}s"
          },
          w.legend == null ? {} : { legendTemplate = w.legend }
        )]
        thresholds = [for t in w.thresholds : merge(
          { value = t.value, targetAxis = "Y1" },
          t.label == null ? {} : { label = t.label }
        )]
        yAxis = { scale = "LINEAR" }
      }
    } if w.type == "chart"
  }

  scorecard_widgets = {
    for id, w in local.widgets : id => merge(
      {
        title = w.title
        scorecard = merge(
          {
            timeSeriesQuery = local.queries[id]
            thresholds = [for t in w.thresholds : {
              value = t.value, color = t.color, direction = t.direction
            }]
          },
          w.spark ? { sparkChartView = { sparkChartType = "SPARK_LINE" } } : {}
        )
      }
    ) if w.type == "scorecard"
  }

  dashboard_tiles = [
    for id, w in local.widgets : {
      xPos   = w.layout.x * local.grid_unit
      yPos   = w.layout.y * local.grid_unit
      width  = w.layout.width * local.grid_unit
      height = w.layout.height * local.grid_unit
      widget = w.type == "chart" ? local.chart_widgets[id] : local.scorecard_widgets[id]
    }
  ]
}

resource "google_monitoring_dashboard" "overview" {
  project = var.cfg.google.project_id

  dashboard_json = jsonencode({
    displayName = local.monitoring.dashboard_name
    mosaicLayout = {
      columns = 12 * local.grid_unit
      tiles   = local.dashboard_tiles
    }
  })

  depends_on = [google_logging_metric.counter]
}
