resource "google_project_service" "required" {
  for_each = {
    compute  = "compute.googleapis.com",
    secret   = "secretmanager.googleapis.com",
    registry = "artifactregistry.googleapis.com",
  }

  service            = each.value
  disable_on_destroy = false
}
