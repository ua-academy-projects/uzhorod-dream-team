locals {
  project  = var.config.project.id
  prefix   = var.config.project.name_prefix
  cloudsql = var.config.app.POSTGRES_BACKEND == "cloudsql"
  labels   = { iss-prefix = local.prefix }

  alerts = {
    for k, v in var.config.monitoring.alerts : k => v
    if v.enabled && (local.cloudsql || !startswith(k, "cloudsql_"))
  }

  vm_filter   = "resource.type = \"gce_instance\" AND metadata.user_labels.\"iss-prefix\" = \"${local.prefix}\""
  sql_filter  = "resource.type = \"cloudsql_database\" AND resource.label.database_id = monitoring.regex.full_match(\"${local.project}:${local.prefix}-pg-.*\")"
  disk_device = "NOT metric.label.device = monitoring.regex.full_match(\".*loop[0-9]+\")"
}
