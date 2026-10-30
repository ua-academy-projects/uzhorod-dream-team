variable "config" {
  description = "vms part of config.json: service_account_prefix, defaults and machines (each lists only what differs from defaults)"
  # any, not object(): with object() a missing field becomes null and merge() would overwrite the default with it.
  type = any

  validation {
    condition = alltrue([
      for machine in values(var.config.machines) :
      length(setsubtract(keys(machine), ["type", "zone", "image", "disk_size", "disk_type", "subnet", "image_tag", "port", "data_disk"])) == 0
    ])
    error_message = "vms.machines: allowed keys are type, zone, image, disk_size, disk_type, subnet, image_tag, port, data_disk."
  }
}

variable "project" {
  description = "project part of config.json"
  type = object({
    id     = string
    region = string
    labels = map(string)
  })
}

variable "backend" {
  description = "Queue backend of the app: postgres or redis"
  type        = string
}

variable "subnets" {
  description = "Subnet role (private, management) => self_link, from the network module"
  type        = map(string)
}

variable "registry" {
  description = "Image repository, from the artifact_registry module"
  type = object({
    repository_id = string
    location      = string
    name          = string
    registry_uri  = string
  })
}
