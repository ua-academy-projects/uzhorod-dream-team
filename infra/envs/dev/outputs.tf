output "bastion_ip" {
  description = "The only public address"
  value       = one([for vm in module.vm : vm.external_ip if vm.bastion])

  precondition {
    condition     = length([for vm in module.vm : vm if vm.bastion]) == 1
    error_message = "config.json: exactly one VM must have \"bastion\": true."
  }
}

output "placement" {
  description = "Which VM runs what, at which address"
  value       = { for name, vm in local.config.vms : name => "${module.vm[name].internal_ip}  ${join(", ", vm.services)}" }
}

output "secret_readers" {
  description = "Which VM may read which secret"
  value       = module.secrets.readers
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
  value       = "ssh -i ~/.ssh/citybikes_ed25519 ${local.config.ssh.user}@${one([for vm in module.vm : vm.external_ip if vm.bastion])}"
}

output "logs" {
  description = "The containers' logs of the VMs with cloud_logging (terminal, or Logs Explorer in the console)"
  value = {
    terminal = "gcloud logging read 'logName=\"projects/${var.project_id}/logs/gcplogs-docker-driver\"' --limit 20 --format='table(timestamp, jsonPayload.container.name, jsonPayload.message)'"
    console  = "https://console.cloud.google.com/logs/query;query=logName%3D%22projects%2F${var.project_id}%2Flogs%2Fgcplogs-docker-driver%22?project=${var.project_id}"
  }
}
