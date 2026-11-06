variable "config" {
  description = "config.json; this module reads project, app (backend and database) and vms: defaults and machines (each lists only what differs from defaults)"
  type        = any

  validation {
    condition = alltrue([
      for machine in values(var.config.vms.machines) :
      length(setsubtract(keys(machine), ["type", "zone", "image", "disk_size", "disk_type", "subnet", "image_tag", "port", "data_disk", "backends", "databases"])) == 0
    ])
    error_message = "vms.machines: allowed keys are type, zone, image, disk_size, disk_type, subnet, image_tag, port, data_disk, backends, databases."
  }

  validation {
    condition = alltrue([
      for machine in values(var.config.vms.machines) :
      length(setsubtract(machine.backends, ["postgres", "redis"])) == 0 if can(machine.backends)
    ])
    error_message = "vms.machines.<vm>.backends may only list postgres and redis."
  }

  validation {
    condition = alltrue([
      for machine in values(var.config.vms.machines) :
      length(setsubtract(machine.databases, ["cloud_sql", "vm"])) == 0 if can(machine.databases)
    ])
    error_message = "vms.machines.<vm>.databases may only list cloud_sql and vm."
  }

  validation {
    condition = alltrue([
      for machine in values(var.config.vms.machines) :
      length(setsubtract(["name", "size", "type", "device_name"], keys(machine.data_disk))) == 0 if can(machine.data_disk)
    ])
    error_message = "vms.machines.<vm>.data_disk needs name, size, type and device_name."
  }
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
  })
}

variable "service_accounts" {
  description = "VM name => email of its service account, from the service_accounts module"
  type        = map(string)
}
