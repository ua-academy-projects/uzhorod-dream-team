variable "cfg" {
  type = object({
    google = object({
      project_id = string
      region     = string
      zone       = string
    })
    vm = object({
      name_prefix = optional(string, "kyiv-air")
      deploy      = optional(bool, true)
      ssh_port    = optional(number, 222)
      bastion_ssh = optional(bool, false)
      instances = map(object({
        machine_type = optional(string, "e2-micro")
        private_ip   = string
        tags         = set(string)
        boot_disk = object({
          image   = optional(string, "ubuntu-os-cloud/ubuntu-minimal-2604-lts-amd64")
          size_gb = number
          type    = optional(string, "pd-balanced")
        })
        data_disk = optional(object({
          size_gb     = number
          type        = string
          device_name = string
        }))
      }))
    })
    network = object({
      public_tier = optional(string, "STANDARD")
    })
    modes = object({
      postgres_only = bool
      cloud_sql     = bool
    })
  })
}

variable "service_accounts" {
  type = map(object({
    email = string
  }))
  description = "Mapper of VMs to their GCP service accounts"
}

variable "network" {
  type = object({
    subnetwork_id = string
    public_ips    = optional(map(string), null)
  })
  description = "Network outputs"
}
