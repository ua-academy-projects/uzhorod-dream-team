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
  description = "How you log in to it (the bastion only; the others: from the bastion)"
  value = local.vm.bastion ? format("ssh -i %s -p %d %s@%s",
    trimsuffix(local.ssh.user_public_key_file, ".pub"), local.ssh.bastion_port, local.ssh.user,
  google_compute_address.external[0].address) : null
}