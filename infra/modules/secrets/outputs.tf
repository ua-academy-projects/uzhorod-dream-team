
output "readers" {
  description = "cloud => { secret name => the VMs that may read it }"
  value       = { for secrets in module.gcp : "gcp" => secrets.readers } 
}
