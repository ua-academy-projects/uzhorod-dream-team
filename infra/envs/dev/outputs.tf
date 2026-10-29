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

output "fill_secrets" {
  description = "Run once after the first apply. Reads the values from your shell: set -a; source .env; set +a"
  value = join("\n", concat(
    [
      for name, id in local.secret_ids :
      # the variable in the project's .env (the tunnel token has a longer name there)
      "printf '%s' \"$${${name == "TUNNEL_TOKEN" ? "CLOUDFLARE_TUNNEL_TOKEN" : name}}\" | gcloud secrets versions add ${id} --data-file=-"
      if contains(keys(local.secret_readers), id)
    ],
    ["gcloud secrets versions add ${local.ssh_key_secret} --data-file=$HOME/.ssh/citybikes_internal_ed25519"],
  ))
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
