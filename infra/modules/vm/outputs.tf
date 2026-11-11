output "internal_ip" {
  value = google_compute_address.internal.address
}

output "external_ip" {
  value = local.vm.bastion ? google_compute_address.external[0].address : null
}

output "bastion" {
  value = local.vm.bastion
}

output "placement" {
  description = "Its address and what runs on it"
  value       = "${google_compute_address.internal.address}  ${join(", ", local.vm.services)}"
}

output "ssh" {
  description = "How you log in to it (the bastion only; the others through it). First: ansible-playbook citybikes.infra.access"
  value       = local.vm.bastion ? format("ssh -p %d %s@%s", local.ssh.bastion_port, local.ssh.user, google_compute_address.external[0].address) : null
}