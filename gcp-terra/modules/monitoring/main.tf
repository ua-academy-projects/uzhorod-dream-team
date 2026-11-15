locals {
  enabled           = var.monitoring.enabled
  sql_instance_name = try(var.config.cloud_sql.managed, false) ? var.config.cloud_sql.instance_name : null
  ui_host           = try(var.public_ips["ui"], null)
  agent_accounts    = { for key, email in var.service_account_emails : key => email if local.enabled && var.monitoring.agent.enabled && key != "bastion" && contains(keys(var.instance_ids), key) }
  config            = var.monitoring
}

locals {
  vm_scope    = "resource.type = \"gce_instance\" AND (${join(" OR ", [for id in values(var.instance_ids) : "resource.labels.instance_id = \"${id}\""])})"
  agent_scope = "resource.type = \"gce_instance\" AND (${join(" OR ", [for key, id in var.instance_ids : "resource.labels.instance_id = \"${id}\"" if key != "bastion"])})"
  sql_scope   = local.sql_instance_name == null ? null : "resource.type = \"cloudsql_database\" AND resource.labels.database_id = \"${var.config.project_id}:${local.sql_instance_name}\""
  scopes      = { vm = local.vm_scope, agent = local.agent_scope, sql = local.sql_scope }
  metrics = { for key, metric in local.config.metrics : key => merge(metric, {
    filter = "${local.scopes[metric.scope]} AND ${metric.filter}"
  }) if local.enabled && metric.enabled && (metric.scope != "sql" || local.sql_instance_name != null) }
}
