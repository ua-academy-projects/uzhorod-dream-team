variable "config" {
  description = "Конфігурація мережі"

  type = object({
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
}