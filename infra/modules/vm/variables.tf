variable "config" {
  description = "One VM: its entry of config.json \"vms\" + where it lives and who may log in"
  type = object({

    host         = number
    machine_type = string
    disk_size_gb = number
    image        = optional(string, "ubuntu-os-cloud/ubuntu-2404-lts-amd64")
    bastion      = optional(bool, false)
    secrets      = optional(list(string), [])


    name            = string
    service_account = string
    region          = string
    zone            = string
    subnetwork_id   = string
    subnet_cidr     = string
    bastion_tag     = string
    labels          = map(string)
    ssh             = object({ user = string, user_public_key_file = string, internal_public_key_file = string })
  })

  validation {
    condition     = !var.config.bastion || contains(var.config.secrets, "internal-ssh-key")
    error_message = "config.json: the bastion needs \"internal-ssh-key\" in its \"secrets\"."
  }
}
