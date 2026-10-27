resource "google_project_service" "this" {
  for_each = toset(var.services)

  service                    = each.value
  disable_dependent_services = false
  # Other resources of the project may rely on them: destroy must not switch them off.
  disable_on_destroy = false
}
