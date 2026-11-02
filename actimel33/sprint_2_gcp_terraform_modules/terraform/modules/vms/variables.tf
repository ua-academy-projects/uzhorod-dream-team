variable "config" {
  description = "config.json; this module reads project, app.backend and vms: service_account_prefix, defaults and machines (each lists only what differs from defaults)"
  type        = any

  validation {
    condition = alltrue([
      for machine in values(var.config.vms.machines) :
      length(setsubtract(keys(machine), ["type", "zone", "image", "disk_size", "disk_type", "subnet", "image_tag", "port", "data_disk", "backends"])) == 0
    ])
    error_message = "vms.machines: allowed keys are type, zone, image, disk_size, disk_type, subnet, image_tag, port, data_disk, backends."
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

variable "database" {
  description = "How the VMs reach Postgres in Cloud SQL (from the cloud_sql module)"
  type = object({
    host            = string
    ca_cert         = string
    name            = string
    user            = string
    password_secret = string
  })
}
