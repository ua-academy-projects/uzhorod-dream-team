# public address of the bastion (ephemeral); ansible takes it from the dynamic inventory, this output is for manual ssh
output "bastion_ip" {
  value = module.instances.public_ips["bastion"]
}

# point the A record of services.frontend.domain at this address
output "frontend_ip" {
  value = module.instances.public_ips["frontend"]
}

# Cloud SQL private address (allocated from the PSA range, so it is not in config.json); pass it to ansible:
#   -e queue_env_cloudsql_host=$(terraform output -raw cloudsql_private_ip)
output "cloudsql_private_ip" {
  value = module.cloudsql.private_ip
}
