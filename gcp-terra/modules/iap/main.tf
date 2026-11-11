resource "google_project_service" "iap" {
  project            = var.config.project_id
  service            = "iap.googleapis.com"
  disable_on_destroy = false
  lifecycle {
    precondition {
      condition     = length(var.members) > 0
      error_message = "Set iap_members to an explicit operator identity before migrating the bastion to private IAP access."
    }
  }
}

resource "google_iap_tunnel_instance_iam_member" "operator" {
  for_each = var.members
  project  = var.config.project_id
  zone     = var.config.zone
  instance = var.config.compute.instances.bastion.name
  role     = "roles/iap.tunnelResourceAccessor"
  member   = each.value
  condition {
    title      = "bastion-ssh-only"
    expression = "destination.port == ${var.config.compute.instances.bastion.startup.ssh_port}"
  }
  depends_on = [google_project_service.iap]
}
