output "bastion_public_ip" {
  value = try(module.vm[local.bastion].external_ip, null)
}

output "internal_ips" {
  value = module.network.ips
}

output "cloudsql_connection_name" {
  value = one(module.cloudsql[*].connection_name)
}

output "monitoring_dashboard_url" {
  value = one(module.monitoring[*].dashboard_url)
}

output "ssh_config" {
  value = "${join("\n\n", [for k, m in module.vm : join("\n", compact([
    "Host gcp-${m.name}",
    "  HostName ${k == local.bastion ? coalesce(m.external_ip, "") : module.network.ips[k]}",
    k == local.bastion ? "  Port ${module.cloud_init.ssh_port}" : "",
    "  User ${k == local.bastion ? "jump" : module.cloud_init.admin_user}",
    "  IdentityFile ${module.cloud_init.ssh_identity_file}",
    "  IdentitiesOnly yes",
    "  UserKnownHostsFile ~/.ssh/iss_gcp/known_hosts",
    "  StrictHostKeyChecking accept-new",
    "  LogLevel ERROR",
    k == local.bastion ? "" : "  ProxyJump gcp-${try(module.vm[local.bastion].name, "")}",
  ]))])}\n"
}

output "iap_ssh" {
  value = "gcloud compute ssh <vm> --project ${local.cfg.project.id} --zone ${local.cfg.project.zone} --tunnel-through-iap (bastion: add --ssh-flag=-p${module.cloud_init.ssh_port})"
}
