locals {
  project        = var.config.project.id
  prefix         = var.config.project.name_prefix
  cloudsql       = var.config.app.POSTGRES_BACKEND == "cloudsql"
  dashboard_name = "${local.prefix} overview"

  vm_filter    = var.filters.vm
  sql_filter   = var.filters.sql
  disk_device  = "NOT metric.label.device = monitoring.regex.full_match(\".*(loop[0-9]+|[a-z]1[56])\")"
  log_filters  = var.log_filters
  policy_names = [for n in var.policy_names : regex("alertPolicies/[^/]+$", n)]

  thresholds = { for k, v in var.config.monitoring.alerts : k => v.threshold if v.threshold != null }

  requests     = "${var.promql.iss_nginx_requests}{monitored_resource=\"gce_instance\"}"
  requests_5xx = "${var.promql.iss_nginx_requests}{monitored_resource=\"gce_instance\",class=\"5\"}"
}
