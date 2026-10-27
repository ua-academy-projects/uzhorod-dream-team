resource "local_file" "this" {
  filename        = var.filename
  file_permission = "0600"

  content = templatefile("${path.module}/ssh_config.tftpl", {
    bastion_name = var.bastion_name
    project      = var.project
    zone         = var.zone
    user         = var.ssh_user
    hosts        = var.hosts
  })
}
