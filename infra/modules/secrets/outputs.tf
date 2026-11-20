output "by_cloud" {
  description = "cloud => { secret (its config.json name) => its id in that cloud }: for modules/vm, where each VM grants itself access"
  value = merge(
    { for secrets in module.gcp : "gcp" => secrets.ids },
    { for secrets in module.aws : "aws" => secrets.ids },
  )
}

output "readers" {
  description = "cloud => { secret name in the cloud => the VMs that read it }: what to fill in after apply"
  value = {
    for cloud, secrets in local.by_cloud : cloud => {
      for secret in secrets : "${var.config.prefix}-${secret}" => sort([
        for reader in local.readers : reader.name if reader.cloud == cloud && contains(reader.secrets, secret)
      ])
    }
  }
}
