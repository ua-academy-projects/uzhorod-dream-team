output "user_data" {
  value = {
    for k, r in local.roles : k => "#cloud-config\n${r == "bastion" ? yamlencode(local.bastion_cloud_config) : yamlencode(local.app_cloud_config)}"
  }
}

output "admin_user" {
  value = local.admin_user
}

output "bastion" {
  value = local.bastion
}

output "ssh_port" {
  value = var.config.access.ssh_port
}

output "ssh_identity_file" {
  value = trimsuffix(var.config.access.ssh_public_key, ".pub")
}
