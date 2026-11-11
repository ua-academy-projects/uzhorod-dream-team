locals {
  monitoring = var.cfg.monitoring
  widgets    = { for w in local.monitoring.widgets : w.id => w }

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
    for id, w in local.widgets : id => {
      timeSeriesFilter = {
        filter      = local.filters[id]
        aggregation = local.aggregations[id]
      }
    }
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
    for id, w in local.widgets : id => {
      title = w.title
      scorecard = {
        timeSeriesQuery = local.queries[id]
        thresholds = [for t in w.thresholds : {
          value = t.value, color = t.color, direction = t.direction
        }]
      }
    } if w.type == "scorecard"
  }

  dashboard_widgets = [
    for w in local.monitoring.widgets :
    w.type == "chart" ? local.chart_widgets[w.id] : local.scorecard_widgets[w.id]
  ]
}

resource "google_monitoring_dashboard" "this" {
  project = var.cfg.google.project_id

  dashboard_json = jsonencode({
    displayName = local.monitoring.dashboard_name
    gridLayout = {
      columns = "2"
      widgets = local.dashboard_widgets
    }
  })
}
