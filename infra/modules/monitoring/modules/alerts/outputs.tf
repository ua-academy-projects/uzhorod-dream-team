output "policies" {
  value = {
    for k, p in google_monitoring_alert_policy.this : k => {
      name            = p.name
      display_name    = p.display_name
      severity        = p.severity
      labels          = p.user_labels
      subject         = p.documentation[0].subject
      channels        = length(p.notification_channels)
      duration        = local.policies[k].kind == "promql" ? p.conditions[0].condition_prometheus_query_language[0].duration : local.policies[k].kind == "threshold" ? p.conditions[0].condition_threshold[0].duration : p.conditions[0].condition_absent[0].duration
      query_or_filter = coalesce(local.policies[k].query, local.policies[k].filter)

      metric_validation_disabled = try(p.conditions[0].condition_prometheus_query_language[0].disable_metric_validation, false)
    }
  }
}

output "policy_names" {
  value = [for p in google_monitoring_alert_policy.this : p.name]
}

output "channels" {
  value = { for k, c in google_monitoring_notification_channel.email : k => c.name }
}

output "filters" {
  value = {
    vm          = local.vm_filter
    sql         = local.sql_filter
    disk_device = local.disk_device
  }
}
