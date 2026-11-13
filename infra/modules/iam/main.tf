locals {
  # roles every VM gets
  base_roles = ["roles/logging.logWriter", "roles/monitoring.metricWriter"]

  artifact_readers = toset([for k, v in var.instances : k if contains(v.access, "artifacts")])
  cloudsql_clients = toset([for k, v in var.instances : k if contains(v.access, "cloudsql")])

  # ansible_roles = [
  #   "roles/compute.viewer",
  #   "roles/compute.osAdminLogin",
  #   "roles/iap.tunnelResourceAccessor",
  #   "roles/iam.serviceAccountUser",
  # ]
}

# --- VM identities: one per instance, named after it ---------------------------
resource "google_service_account" "vm" {
  for_each     = var.instances
  account_id   = each.key
  display_name = each.key
}

resource "google_project_iam_member" "vm_base" {
  for_each = {
    for p in setproduct(keys(var.instances), local.base_roles) : "${p[0]}/${p[1]}" => { vm = p[0], role = p[1] }
  }
  project = var.project_id
  role    = each.value.role
  member  = "serviceAccount:${google_service_account.vm[each.value.vm].email}"
}

resource "google_project_iam_member" "cloudsql_client" {
  for_each = local.cloudsql_clients
  project  = var.project_id
  role     = "roles/cloudsql.client"
  member   = "serviceAccount:${google_service_account.vm[each.key].email}"
}

# --- artifacts bucket ----------------------------------------------------------
resource "google_storage_bucket" "artifacts" {
  name                        = "${var.project_id}-artifacts"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
}

resource "google_storage_bucket_iam_member" "artifact_reader" {
  for_each = local.artifact_readers
  bucket   = google_storage_bucket.artifacts.name
  role     = "roles/storage.objectViewer"
  member   = "serviceAccount:${google_service_account.vm[each.key].email}"
}

# --- ansible -------------------------------------------------------------------
# resource "google_service_account" "ansible" {
#   account_id   = "ansible"
#   display_name = "ansible"
# }

# resource "google_project_iam_member" "ansible" {
#   for_each = toset(local.ansible_roles)
#   project  = var.project_id
#   role     = each.value
#   member   = "serviceAccount:${google_service_account.ansible.email}"
# }

# resource "google_service_account_iam_member" "ansible_operator" {
#   service_account_id = google_service_account.ansible.name
#   role               = "roles/iam.serviceAccountTokenCreator"
#   member             = var.operator_member
# }
