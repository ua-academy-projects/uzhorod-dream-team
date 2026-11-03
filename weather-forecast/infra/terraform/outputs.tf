output "external_ips" {
  value = module.vms.external_ips
}

output "internal_ips" {
  value = module.vms.internal_ips
}

output "secrets" {
  value = module.secrets.names
}

output "cloudsql" {
  value = {
    private_ip = module.cloudsql.private_ip
    instance   = module.cloudsql.instance
  }
}
