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
      alerts = map(object({
        threshold = optional(number)
      }))
    })
  })
}

variable "log_filters" {
  type = map(string)
}

variable "promql" {
  type = map(string)
}

variable "filters" {
  type = object({
    vm  = string
    sql = string
  })
}

variable "policy_names" {
  type = list(string)
}
