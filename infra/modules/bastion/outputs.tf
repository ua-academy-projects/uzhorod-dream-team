output "by_cloud" {
  description = "cloud => { cloud, internal_ip, external_ip } of its bastion (modules/vm reaches its VMs through it)"
  value = merge(
    { for bastion in module.gcp : "gcp" => bastion.addresses.bastion },
    { for bastion in module.aws : "aws" => bastion.addresses.bastion },
  )
}

output "public_ips" {
  description = "cloud => the bastion's public address: the only public addresses"
  value = merge(
    { for bastion in module.gcp : "gcp" => bastion.addresses.bastion.external_ip },
    { for bastion in module.aws : "aws" => bastion.addresses.bastion.external_ip },
  )
}