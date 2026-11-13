variable "config" {
  type = object({
    project = object({
      name_prefix = string
      region      = string
    })
    network = object({
      subnet_cidr = string
      psa_cidr    = string
    })
    vms = map(object({
      host = number
    }))
    app = object({
      POSTGRES_BACKEND = string
    })
  })

  validation {
    condition = !can(cidrhost(var.config.network.psa_cidr, 0)) || !can(cidrhost(var.config.network.subnet_cidr, 0)) || (
      cidrhost("${split("/", var.config.network.psa_cidr)[0]}/${min(tonumber(split("/", var.config.network.psa_cidr)[1]), tonumber(split("/", var.config.network.subnet_cidr)[1]))}", 0) !=
      cidrhost("${split("/", var.config.network.subnet_cidr)[0]}/${min(tonumber(split("/", var.config.network.psa_cidr)[1]), tonumber(split("/", var.config.network.subnet_cidr)[1]))}", 0)
    )
    error_message = "network.psa_cidr must not overlap network.subnet_cidr."
  }

  validation {
    condition     = length(distinct([for v in values(var.config.vms) : v.host])) == length(var.config.vms)
    error_message = "Every VM must have a unique host number in vms."
  }

  validation {
    condition     = alltrue([for v in values(var.config.vms) : can(cidrhost(var.config.network.subnet_cidr, v.host))])
    error_message = "Every host number must fit inside network.subnet_cidr."
  }

  validation {
    condition     = alltrue([for v in values(var.config.vms) : v.host >= 2 && try(v.host <= pow(2, 32 - tonumber(split("/", var.config.network.subnet_cidr)[1])) - 3, true)])
    error_message = "Host numbers 0, 1 and the last two addresses of network.subnet_cidr are reserved by GCP."
  }
}
