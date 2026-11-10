resource "google_service_account" "vm" {
  for_each = {
    for name, cfg in local.cfg.vm.instances :
    name => cfg if lookup(cfg, "needs_registry", false) || length(toset(lookup(cfg, "secrets", []))) > 0
  }

  account_id   = "kyiv-air-${each.key}"
  display_name = "Kyiv Air ${title(each.key)}"
}

resource "google_project_iam_member" "ops_agent" {
  for_each = {
    for pair in setproduct(keys(google_service_account.vm), ["roles/monitoring.metricWriter", "roles/logging.logWriter"]) :
    "${pair[0]}-${pair[1]}" => { name = pair[0], role = pair[1] }
  }

  project = local.cfg.google.project_id
  role    = each.value.role
  member  = "serviceAccount:${google_service_account.vm[each.value.name].email}"
}
