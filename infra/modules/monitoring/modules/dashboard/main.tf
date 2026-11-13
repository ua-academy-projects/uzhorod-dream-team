locals {
  share_query = "sum(rate(${local.requests_5xx}[5m])) / sum(rate(${local.requests}[5m]))"

  user_metric = "resource.type = \"gce_instance\" AND metric.type = \"logging.googleapis.com/user/%s\""

  series = {
    requests  = { filter = format(local.user_metric, "iss_nginx_requests"), aligner = "ALIGN_RATE", reducer = "REDUCE_SUM", group = ["metric.label.class"], plot = "STACKED_BAR", legend = "$${metric.labels.class}xx" }
    positions = { filter = format(local.user_metric, "iss_positions"), aligner = "ALIGN_DELTA", reducer = "REDUCE_SUM", group = ["metric.label.event"], plot = "LINE", legend = "$${metric.labels.event}" }
    errors    = { filter = format(local.user_metric, "iss_container_errors"), aligner = "ALIGN_DELTA", reducer = "REDUCE_SUM", group = ["metric.label.container"], plot = "STACKED_BAR", legend = "$${metric.labels.container}" }
    cpu       = { filter = "metric.type = \"compute.googleapis.com/instance/cpu/utilization\" AND ${local.vm_filter}", aligner = "ALIGN_MEAN", reducer = "REDUCE_MEAN", group = ["metric.label.instance_name"], plot = "LINE", legend = "$${metric.labels.instance_name}" }
    memory    = { filter = "metric.type = \"agent.googleapis.com/memory/percent_used\" AND metric.label.state = \"used\" AND ${local.vm_filter}", aligner = "ALIGN_MEAN", reducer = "REDUCE_MEAN", group = ["metadata.system_labels.name"], plot = "LINE", legend = "" }
    disk      = { filter = "metric.type = \"agent.googleapis.com/disk/percent_used\" AND metric.label.state = \"used\" AND ${local.disk_device} AND ${local.vm_filter}", aligner = "ALIGN_MEAN", reducer = "REDUCE_MEAN", group = ["metadata.system_labels.name"], plot = "LINE", legend = "" }
    sql_cpu   = { filter = "metric.type = \"cloudsql.googleapis.com/database/cpu/utilization\" AND ${local.sql_filter}", aligner = "ALIGN_MEAN", reducer = "REDUCE_MEAN", group = [], plot = "LINE", legend = "CPU" }
    sql_mem   = { filter = "metric.type = \"cloudsql.googleapis.com/database/memory/utilization\" AND ${local.sql_filter}", aligner = "ALIGN_MEAN", reducer = "REDUCE_MEAN", group = [], plot = "LINE", legend = "memory" }
    sql_disk  = { filter = "metric.type = \"cloudsql.googleapis.com/database/disk/utilization\" AND ${local.sql_filter}", aligner = "ALIGN_MEAN", reducer = "REDUCE_MEAN", group = [], plot = "LINE", legend = "disk" }
    sql_conn  = { filter = "metric.type = \"cloudsql.googleapis.com/database/postgresql/num_backends\" AND ${local.sql_filter}", aligner = "ALIGN_MEAN", reducer = "REDUCE_SUM", group = [], plot = "LINE", legend = "connections" }
  }

  fractions = ["sql_cpu", "sql_mem", "sql_disk"]

  query = {
    for k, v in local.series : k => merge({
      timeSeriesFilter = {
        filter = v.filter
        aggregation = merge({
          alignmentPeriod    = "60s"
          perSeriesAligner   = v.aligner
          crossSeriesReducer = v.reducer
        }, length(v.group) > 0 ? { groupByFields = v.group } : {})
      }
    }, contains(local.fractions, k) ? { unitOverride = "10^2.%" } : {})
  }

  xy = {
    for k, v in local.series : k => {
      xyChart = {
        dataSets = [merge({
          plotType        = v.plot
          targetAxis      = "Y1"
          timeSeriesQuery = local.query[k]
        }, v.legend != "" ? { legendTemplate = v.legend } : {})]
      }
    }
  }

  percentile = {
    for p in ["50", "95"] : p => {
      plotType       = "LINE"
      targetAxis     = "Y1"
      legendTemplate = "p${p}"
      timeSeriesQuery = {
        timeSeriesFilter = {
          filter = format(local.user_metric, "iss_nginx_request_time")
          aggregation = {
            alignmentPeriod    = "300s"
            perSeriesAligner   = "ALIGN_DELTA"
            crossSeriesReducer = "REDUCE_PERCENTILE_${p}"
          }
        }
      }
    }
  }

  heatmap = {
    xyChart = {
      dataSets = [{
        plotType   = "HEATMAP"
        targetAxis = "Y1"
        timeSeriesQuery = {
          timeSeriesFilter = {
            filter = format(local.user_metric, "iss_nginx_request_time")
            aggregation = {
              alignmentPeriod    = "60s"
              perSeriesAligner   = "ALIGN_DELTA"
              crossSeriesReducer = "REDUCE_SUM"
            }
          }
        }
      }]
    }
  }

  donut = {
    for k, v in {
      status = { metric = "iss_nginx_requests", group = "class", slice = "$${metric.labels.class}xx" }
      errors = { metric = "iss_container_errors", group = "container", slice = "$${metric.labels.container}" }
      } : k => {
      pieChart = {
        chartType  = "DONUT"
        showLabels = true
        dataSets = [{
          sliceNameTemplate = v.slice
          timeSeriesQuery = {
            timeSeriesFilter = {
              filter = format(local.user_metric, v.metric)
              aggregation = {
                alignmentPeriod    = "3600s"
                perSeriesAligner   = "ALIGN_DELTA"
                crossSeriesReducer = "REDUCE_SUM"
                groupByFields      = ["metric.label.${v.group}"]
              }
            }
          }
        }]
      }
    }
  }

  share_max     = min(1, try(local.thresholds.nginx_5xx_share * 4, 1))
  red_above     = { for k in ["nginx_5xx_share", "cloudsql_disk"] : k => try([{ value = local.thresholds[k], color = "RED", direction = "ABOVE" }], []) }
  thresholds_of = { for k, v in local.red_above : k => length(v) > 0 ? { thresholds = v } : {} }

  scorecard = {
    requests = {
      scorecard = {
        sparkChartView = { sparkChartType = "SPARK_LINE" }
        timeSeriesQuery = {
          timeSeriesFilter = {
            filter      = format(local.user_metric, "iss_nginx_requests")
            aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_RATE", crossSeriesReducer = "REDUCE_SUM" }
          }
        }
      }
    }
    share = {
      scorecard = merge({
        gaugeView       = { upperBound = local.share_max }
        timeSeriesQuery = { prometheusQuery = local.share_query }
      }, local.thresholds_of.nginx_5xx_share)
    }
    positions = {
      scorecard = {
        sparkChartView = { sparkChartType = "SPARK_LINE" }
        thresholds     = [{ value = 1, color = "RED", direction = "BELOW" }]
        timeSeriesQuery = {
          timeSeriesFilter = {
            filter      = "${format(local.user_metric, "iss_positions")} AND metric.label.event = \"stored\""
            aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_DELTA", crossSeriesReducer = "REDUCE_SUM" }
          }
        }
      }
    }
    sql_disk = {
      scorecard = merge({
        gaugeView       = { upperBound = 1 }
        timeSeriesQuery = local.query.sql_disk
      }, local.thresholds_of.cloudsql_disk)
    }
  }

  table = {
    timeSeriesTable = {
      metricVisualization = "BAR"
      dataSets = [
        { timeSeriesQuery = local.query.disk },
      ]
    }
  }

  logs = {
    for k, v in {
      nginx  = local.log_filters.iss_nginx_requests
      errors = local.log_filters.iss_container_errors
    } : k => { logsPanel = { filter = v, resourceNames = ["projects/${local.project}"] } }
  }

  rows = [
    {
      height = 8
      tiles = [
        merge({ title = "Requests per second" }, local.scorecard.requests),
        merge({ title = "5xx share now" }, local.scorecard.share),
        merge({ title = "Positions stored per minute" }, local.scorecard.positions),
      ]
    },
    {
      height = 16
      tiles = [
        merge({ title = "Requests/s by status class" }, local.xy.requests),
        merge({ title = "Status share, last hour" }, local.donut.status),
        merge({ title = "Response time distribution, s" }, local.heatmap),
        { title = "Response time p50 / p95, s", xyChart = { dataSets = [local.percentile["50"], local.percentile["95"]] } },
      ]
    },
    {
      height = 16
      tiles = concat(
        [
          merge({ title = "Positions per minute (published / stored)" }, local.xy.positions),
          merge({ title = "Error share by container, last hour" }, local.donut.errors),
          merge({ title = "Error lines per minute by container" }, local.xy.errors),
        ],
        length(local.policy_names) > 0 ? [{ title = "Open incidents", incidentList = { policyNames = local.policy_names } }] : [],
      )
    },
    {
      height = 16
      tiles = [
        merge({ title = "Root disk used % now" }, local.table),
        merge({ title = "CPU utilization by VM (shared-core VMs can exceed 100%)" }, local.xy.cpu),
        merge({ title = "Memory used % by VM" }, local.xy.memory),
        merge({ title = "Root disk used % by VM" }, local.xy.disk),
      ]
    },
    {
      height = 16
      tiles = slice([
        merge({ title = "Cloud SQL disk used %" }, local.scorecard.sql_disk),
        merge({ title = "Cloud SQL CPU utilization %" }, local.xy.sql_cpu),
        merge({ title = "Cloud SQL memory used %" }, local.xy.sql_mem),
        merge({ title = "Cloud SQL connections" }, local.xy.sql_conn),
      ], 0, local.cloudsql ? 4 : 0)
    },
    {
      height = 16
      tiles = [
        merge({ title = "nginx access log" }, local.logs.nginx),
        merge({ title = "Error log lines" }, local.logs.errors),
      ]
    },
  ]

  placed_rows = [for row in local.rows : row if length(row.tiles) > 0]
  row_tops    = [for r in range(length(local.placed_rows)) : r == 0 ? 0 : sum([for i in range(r) : local.placed_rows[i].height])]

  tiles = flatten([
    for r, row in local.placed_rows : [
      for c, widget in row.tiles : {
        for k, v in {
          xPos   = c * floor(48 / length(row.tiles))
          yPos   = local.row_tops[r]
          width  = floor(48 / length(row.tiles))
          height = row.height
          widget = widget
        } : k => v if !(contains(["xPos", "yPos"], k) && v == 0)
      }
    ]
  ])

  dashboard_json = jsonencode({
    displayName  = local.dashboard_name
    labels       = { iss-prefix = "" }
    mosaicLayout = { columns = 48, tiles = local.tiles }
  })
}

resource "google_monitoring_dashboard" "this" {
  dashboard_json = local.dashboard_json
}
