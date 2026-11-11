variable "config" {
  description = "Shared configuration; this module selects its own settings."
  type = object({
    network = object({
      name = string

      subnet = object({
        name   = string
        cidr   = string
        region = string
      })

      nat = object({
        name    = string
        enabled = optional(bool, true)
      })
    })
  })
}
