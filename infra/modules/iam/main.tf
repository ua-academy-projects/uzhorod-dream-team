locals {
  cloudsql_keys  = toset([for k, v in var.config.vms : k if v.service_account && var.config.app.POSTGRES_BACKEND == "cloudsql" && contains(var.vm_keys, k)])
  agent_keys     = var.config.monitoring.ops_agent ? var.vm_keys : toset([])
  app_keys       = toset([for k in var.vm_keys : k if !var.config.vms[k].bastion])
  keys           = setunion(local.cloudsql_keys, local.agent_keys, local.app_keys)
  cloudsql_roles = ["roles/cloudsql.client", "roles/cloudsql.instanceUser"]
  agent_roles    = ["roles/logging.logWriter", "roles/monitoring.metricWriter"]
  grants = merge(
    { for pair in setproduct(local.cloudsql_keys, local.cloudsql_roles) : "${pair[0]}/${pair[1]}" => { key = pair[0], role = pair[1] } },
    { for pair in setproduct(local.agent_keys, local.agent_roles) : "${pair[0]}/${pair[1]}" => { key = pair[0], role = pair[1] } },
  )
  container_secrets = ["CF_TUNNEL_TOKEN", "CLOUDFLARE_API_TOKEN", "POSTGRES_FETCHER_PASSWORD", "POSTGRES_HISTORY_PASSWORD", "POSTGRES_PASSWORD", "RABBITMQ_PASSWORD", "RABBITMQ_USER", "REDIS_PASSWORD"]
  postgres_secrets  = ["POSTGRES_FETCHER_PASSWORD", "POSTGRES_HISTORY_PASSWORD", "POSTGRES_PASSWORD"]
  vm_secrets        = setsubtract(toset(local.container_secrets), var.config.app.POSTGRES_BACKEND == "cloudsql" ? toset(local.postgres_secrets) : toset([]))
  compose_secrets = {
    for k in local.app_keys : k => sort(setintersection(
      toset(flatten(regexall("\\$\\{([A-Z_][A-Z0-9_]*)", file("${path.root}/../deploy/${k}/compose.yaml")))),
      local.vm_secrets,
    ))
  }
  secret_grants = { for k, v in local.compose_secrets : k => v if length(v) > 0 }
}

data "google_client_openid_userinfo" "me" {}

data "google_project" "this" {
  project_id = var.config.project.id
}

resource "google_service_account" "app" {
  for_each = local.keys

  project      = var.config.project.id
  account_id   = "${var.config.project.name_prefix}-${each.key}"
  display_name = "ISS ${each.key}"
}

resource "google_project_iam_member" "grant" {
  for_each = local.grants

  project = var.config.project.id
  role    = each.value.role
  member  = google_service_account.app[each.value.key].member
}

resource "google_project_iam_member" "secrets" {
  for_each = local.secret_grants

  project = var.config.project.id
  role    = "roles/secretmanager.secretAccessor"
  member  = google_service_account.app[each.key].member

  condition {
    title      = "iss-secrets-${each.key}"
    expression = join(" || ", [for s in each.value : "resource.name.startsWith(\"projects/${data.google_project.this.number}/secrets/${s}/\")"])
  }
}

resource "google_service_account_iam_member" "terraform_user" {
  for_each = local.keys

  service_account_id = google_service_account.app[each.key].name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${data.google_client_openid_userinfo.me.email}"
}

resource "time_sleep" "iam" {
  create_duration = "30s"

  triggers = {
    emails  = join(",", sort([for a in google_service_account.app : a.email]))
    secrets = join(",", sort([for k, v in local.secret_grants : "${k}=${join("+", v)}"]))
  }

  depends_on = [google_project_iam_member.grant, google_project_iam_member.secrets, google_service_account_iam_member.terraform_user]
}
