output "ids" {
  value = sort(local.secrets)
}

output "readers" {
  description = "secret id => the VMs that may read it"
  value       = { for s in local.secrets : s => sort([for vm, ids in local.access : vm if contains(ids, s)]) }
}
