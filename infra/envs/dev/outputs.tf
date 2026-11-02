output "bastion_ip" {
  description = "The only public address"
  value       = module.vm[local.bastion].external_ip
}

output "placement" {
  description = "Which VM runs what, at which address"
  value       = { for name, vm in local.vms : name => "${local.ip[name]}  ${join(", ", vm.services)}" }
}

output "secret_readers" {
  description = "Which VM may read which secret"
  value       = local.secret_readers
}

output "database" {
  description = "Cloud SQL: private address only (reachable from our VMs, not from the internet)"
  value = {
    instance   = module.cloudsql.instance_name
    private_ip = module.cloudsql.private_ip
  }
}

output "ssh" {
  description = "Log in to the bastion; from it: ssh citybikes-db, ssh citybikes-ui, ..."
  value       = "ssh -i ~/.ssh/citybikes_ed25519 ${local.ssh.user}@${module.vm[local.bastion].external_ip}"
}

output "logs" {
  description = "The containers' logs of the VMs with cloud_logging (terminal, or Logs Explorer in the console)"
  value = {
    terminal = "gcloud logging read 'logName=\"projects/${local.project.id}/logs/gcplogs-docker-driver\"' --limit 20 --format='table(timestamp, jsonPayload.container.name, jsonPayload.message)'"
    console  = "https://console.cloud.google.com/logs/query;query=logName%3D%22projects%2F${local.project.id}%2Flogs%2Fgcplogs-docker-driver%22?project=${local.project.id}"
  }
}
