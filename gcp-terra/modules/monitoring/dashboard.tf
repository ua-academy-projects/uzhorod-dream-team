locals {
  dashboard_metrics = merge(local.metrics, local.enabled && local.config.uptime_check.enabled ? {
    uptime = {
      scope     = "uptime"
      filter    = "resource.type = \"uptime_url\" AND metric.type = \"monitoring.googleapis.com/uptime_check/check_passed\" AND metric.labels.check_id = \"${google_monitoring_uptime_check_config.ui[0].uptime_check_id}\""
      scale     = 1
      threshold = 0.99
    }
  } : {})
  dashboard_widgets = [for widget in local.config.dashboard.widgets : widget if contains(keys(local.dashboard_metrics), widget.metric)]
  dashboard_instances = [for widget in local.dashboard_widgets : (
    widget.service != null || strcontains(widget.legend_template, "$${vm_name}") ? [
      for service, id in var.instance_ids : { id = id, name = var.config.compute.instances[service].name }
      if(widget.service == null ? true : widget.service == service) &&
      (local.dashboard_metrics[widget.metric].scope == "vm" || (local.dashboard_metrics[widget.metric].scope == "agent" && service != "bastion"))
    ] : [{ id = null, name = "" }]
  )]
  dashboard_queries = [for index, widget in local.dashboard_widgets : [for instance in local.dashboard_instances[index] : merge({
    timeSeriesFilter = {
      filter = local.dashboard_metrics[widget.metric].scope == "uptime" ? local.dashboard_metrics[widget.metric].filter : "${instance.id == null ? local.scopes[local.dashboard_metrics[widget.metric].scope] : "resource.type = \"gce_instance\" AND resource.labels.instance_id = \"${instance.id}\""} AND ${widget.filter == null ? local.config.metrics[widget.metric].filter : widget.filter}"
      aggregation = merge({
        alignmentPeriod  = local.config.dashboard.alignment_period
        perSeriesAligner = widget.aligner
      }, widget.reducer == "REDUCE_NONE" ? {} : { crossSeriesReducer = widget.reducer }, length(widget.group_by_fields) == 0 ? {} : { groupByFields = widget.group_by_fields })
    }
  }, widget.unit == "" ? {} : { unitOverride = widget.unit }, contains(["donut", "pie"], widget.type) ? { outputFullDuration = true } : {})]]
}

resource "google_monitoring_dashboard" "overview" {
  count   = local.enabled && var.monitoring.dashboard.enabled ? 1 : 0
  project = var.config.project_id
  dashboard_json = jsonencode({
    displayName = var.monitoring.dashboard.display_name
    mosaicLayout = {
      columns = local.config.dashboard.columns
      tiles = [for index, widget in local.dashboard_widgets : merge({
        width  = widget.width
        height = widget.height
        widget = merge({ title = widget.title },
          contains(["line", "bar"], widget.type) ? { xyChart = merge({
            dataSets = [for series_index, query in local.dashboard_queries[index] : merge({
              timeSeriesQuery = query
              plotType        = widget.type == "bar" ? "STACKED_BAR" : "LINE"
              targetAxis      = "Y1"
            }, widget.legend_template == "" ? {} : { legendTemplate = replace(widget.legend_template, "$${vm_name}", local.dashboard_instances[index][series_index].name) })]
            yAxis        = { label = widget.axis_label, scale = "LINEAR" }
            chartOptions = { mode = "COLOR" }
          }, widget.show_threshold ? { thresholds = [{ value = widget.threshold == null ? local.dashboard_metrics[widget.metric].threshold * local.dashboard_metrics[widget.metric].scale : widget.threshold }] } : {}) } : {},
          contains(["donut", "pie"], widget.type) ? { pieChart = {
            chartType  = widget.type == "pie" ? "PIE" : "DONUT"
            showLabels = true
            dataSets = [for series_index, query in local.dashboard_queries[index] : {
              timeSeriesQuery   = query
              sliceNameTemplate = replace(widget.legend_template, "$${vm_name}", local.dashboard_instances[index][series_index].name)
            }]
          } } : {},
          widget.type == "scorecard" ? { scorecard = {
            timeSeriesQuery = local.dashboard_queries[index][0]
            gaugeView       = { upperBound = widget.upper_bound }
            thresholds = [{
              value     = widget.threshold == null ? local.dashboard_metrics[widget.metric].threshold * local.dashboard_metrics[widget.metric].scale : widget.threshold
              direction = widget.threshold_direction
              color     = "RED"
            }]
          } } : {}
        )
      }, widget.x == 0 ? {} : { xPos = widget.x }, widget.y == 0 ? {} : { yPos = widget.y })]
    }
  })
}
