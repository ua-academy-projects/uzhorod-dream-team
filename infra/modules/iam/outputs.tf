output "emails" {
  value      = { for k, a in google_service_account.app : k => a.email }
  depends_on = [time_sleep.iam]
}

output "secret_grants" {
  value = local.secret_grants
}

output "secret_bindings" {
  value = { for k, b in google_project_iam_member.secrets : k => { role = b.role, title = b.condition[0].title, expression = b.condition[0].expression } }
}

output "db_user_names" {
  value      = { for k in local.cloudsql_keys : k => trimsuffix(google_service_account.app[k].email, ".gserviceaccount.com") }
  depends_on = [time_sleep.iam]
}
