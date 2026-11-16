variable "config" {
  description = "infra/config.json as a whole; this module uses prefix and clouds.gcp.permissions"
  type = object({
    prefix = string
    clouds = object({
      gcp = object({
        permissions = map(string)
      })
    })
  })
}

variable "project_id" {
  description = "The GCP project the accounts and their roles live in"
  type        = string
}

variable "vms" {
  description = "The VMs to build and the permissions of each (modules/layout)"
  type        = map(object({ permissions = list(string) }))
}