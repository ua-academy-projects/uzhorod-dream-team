variable "config" {
  type = object({
    project = object({
      id          = string
      name_prefix = string
    })
    app = object({
      POSTGRES_BACKEND = string
    })
    monitoring = object({
      notification_emails = list(string)
      alerts = map(object({
        enabled    = bool
        threshold  = optional(number)
        duration_s = number
      }))
    })
  })
}

variable "promql" {
  type = map(string)
}
