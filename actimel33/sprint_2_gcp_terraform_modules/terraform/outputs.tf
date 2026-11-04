output "infrastructure_ips" {
  description = "VM name => internal IP"
  value       = module.vms.private_ips
}

output "artifact_registry_uri" {
  description = "Where to docker push the images"
  value       = module.artifact_registry.repository.registry_uri
}

output "load_balancer_ip" {
  description = "Public IP of the load balancer, the domain must point to it"
  value       = module.load_balancer.ip
}

resource "local_file" "inventory" {
  filename        = "${path.module}/../ansible/inventory/inventory.ini"
  file_permission = "0644"

  content = templatefile("${path.module}/templates/inventory.ini.tftpl", {
    vms               = module.vms.instances
    project_id        = local.config.project.id
    backend           = local.config.app.backend
    database          = module.cloud_sql.connection
    repository_id     = local.config.registry.repository_id
    history_image_tag = local.config.vms.machines.history.image_tag
    fetcher_image_tag = local.config.vms.machines.fetcher.image_tag
    ui_image_tag      = local.config.vms.machines.ui.image_tag
    region            = local.config.project.region
  })
}

resource "local_file" "db_ca" {
  filename        = "${path.module}/../ansible/files/db-ca.pem"
  file_permission = "0644"
  content         = module.cloud_sql.connection.ca_cert
}
