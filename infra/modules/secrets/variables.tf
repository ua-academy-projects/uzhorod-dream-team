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
    k3s = optional(object({
      cloud = optional(string)
      nodes = map(object({}))
    }))
    database = object({
      type = string
      vm   = string
    })
  })
}
