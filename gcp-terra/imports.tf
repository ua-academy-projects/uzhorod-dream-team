# Adopt the existing Cloud SQL instance and network; no passwords are imported.
# These declarative imports are idempotent after the initial migration.
import {
  for_each = try(local.config.cloud_sql.adopt_existing, false) ? toset(["existing"]) : toset([])
  to       = module.cloud_sql[0].google_project_service.sqladmin
  id       = "${local.config.project_id}/sqladmin.googleapis.com"
}
import {
  for_each = try(local.config.cloud_sql.adopt_existing, false) ? toset(["existing"]) : toset([])
  to       = module.cloud_sql[0].google_project_service.service_networking
  id       = "${local.config.project_id}/servicenetworking.googleapis.com"
}
import {
  for_each = try(local.config.cloud_sql.adopt_existing, false) ? local.config.cloud_sql.private_service_access.ranges : {}
  to       = module.cloud_sql[0].google_compute_global_address.private_services[each.key]
  id       = "projects/${local.config.project_id}/global/addresses/${each.key}"
}
import {
  for_each = try(local.config.cloud_sql.adopt_existing, false) ? toset(["existing"]) : toset([])
  to       = module.cloud_sql[0].google_service_networking_connection.private_services
  id       = "projects/${local.config.project_id}/global/networks/${local.config.network.name}:servicenetworking.googleapis.com"
}
import {
  for_each = try(local.config.cloud_sql.adopt_existing, false) ? toset(["existing"]) : toset([])
  to       = module.cloud_sql[0].google_sql_database_instance.main
  id       = "projects/${local.config.project_id}/instances/${local.config.cloud_sql.instance_name}"
}
import {
  for_each = try(local.config.cloud_sql.adopt_existing, false) ? toset(["existing"]) : toset([])
  to       = module.cloud_sql[0].google_sql_database.application
  id       = "projects/${local.config.project_id}/instances/${local.config.cloud_sql.instance_name}/databases/${local.config.database.name}"
}
