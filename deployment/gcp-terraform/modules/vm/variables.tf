variable "cfg" {
  type = object({
    google = object({
      project_id = string
      region     = string
      zone       = string
    })
    cloudflare = object({
      domain = string
    })
    deploy_vms     = optional(bool, true)
    vm_name_prefix = optional(string, "kyiv-air")
    vm = map(object({
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
      scripts    = set(string)
      entrypoint = string
      env        = optional(map(string), {})
      secrets    = optional(set(string), [])
    }))
    network = object({
      public_tier = optional(string, "STANDARD")
      firewall_rules = map(object({
        ports = set(number)
      }))
    })
    application = object({
      image_version = string
      postgres_only = bool
      database_name = string
      ready_timeout = number
    })
    images = map(string)
    secrets = optional(object({
      versions = optional(map(string), {})
    }), {})
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

variable "registry" {
  type = object({
    repository_url = string
  })
}

variable "secrets" {
  type = object({
    secrets = map(object({
      secret_id = string
      version   = string
    }))
  })
}

variable "cloud_sql" {
  type = object({ connection_name = string })
}
