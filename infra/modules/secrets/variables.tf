variable "config" {
  description = "infra/config.json as a whole; this module uses prefix, default_cloud, vms.instances (cloud, secrets) and database (type, vm)"
  type = object({
    prefix        = string
    default_cloud = string
    vms = object({
      instances = map(object({
        cloud   = optional(string)
        secrets = optional(list(string), [])
      }))
    })
    database = object({
      type = string
      vm   = string
    })
  })
}
