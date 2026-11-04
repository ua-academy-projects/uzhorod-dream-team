variable "config" {
  description = "The secrets and who may read them"
  type = object({
    prefix = string
    vms = map(object({
      secrets = optional(list(string), [])
    }))
    members = map(string)
    labels  = map(string)
  })
}
