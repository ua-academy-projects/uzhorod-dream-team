output "app_url" {
  description = "The application."
  value       = "https://${var.domain}"
}

output "lb_ip" {
  description = "Address of the HTTPS load balancer; the domain points here."
  value       = google_compute_global_address.ui.address
}

output "certificate_check" {
  description = "ACTIVE means HTTPS works."
  value       = "gcloud compute ssl-certificates describe ${google_compute_managed_ssl_certificate.ui.name} --global --format='value(managed.status,managed.domainStatus)'"
}

output "registry" {
  description = "Artifact Registry the VMs pull from."
  value       = local.registry
}

output "bastion_ip" {
  description = "External address of the bastion."
  value       = google_compute_instance.vm["bastion"].network_interface[0].access_config[0].nat_ip
}

output "ssh_config" {
  description = "Paste into ~/.ssh/config.d/crypto-gcp: ssh gcp-db goes through the bastion."
  value = templatefile("${path.module}/templates/ssh_config.tftpl", {
    bastion_ip   = google_compute_instance.vm["bastion"].network_interface[0].access_config[0].nat_ip
    bastion_port = var.bastion_ssh_port
    admin_user   = var.admin_user
    identity     = trimsuffix(var.ssh_public_key_path, ".pub")
    ip           = local.ip
    services     = sort(tolist(local.services))
    known_hosts  = "~/.ssh/known_hosts_gcp"
  })
}
