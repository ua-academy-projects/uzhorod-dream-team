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
  value = one(module.cloudsql)
}
