locals {
  config  = jsondecode(file("${path.module}/../../config.json"))
  ssh     = local.config.ssh
  app     = local.config.app
  project = {
    id     = var.project_id
    region = var.region
    zone   = var.zone
    prefix = local.config.prefix
  }
  network = merge(local.config.network, {
    ssh_allowed_cidrs = ["${var.my_ip}/32"]
  })

  vms = {
    for name, vm in local.config.vms : name => merge({
      bastion       = false
      cloud_logging = false
      image         = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
    }, vm)
  }
  bastion = one([for name, vm in local.vms : name if vm.bastion])

  ip = { for name, vm in local.vms : name => cidrhost(local.network.subnet_cidr, vm.host) }

  labels = { app = local.project.prefix, env = "dev", managed-by = "terraform" }
}

resource "terraform_data" "config_check" {
  lifecycle {
    precondition {
      condition     = length([for vm in local.vms : vm if vm.bastion]) == 1
      error_message = "config.json: exactly one VM must have \"bastion\": true."
    }
    precondition {
      condition     = contains(["rabbitmq", "postgres"], local.app.queue_backend)
      error_message = "config.json: app.queue_backend must be \"rabbitmq\" or \"postgres\"."
    }
    precondition {
      condition     = contains(["redis", "postgres"], local.app.cache_backend)
      error_message = "config.json: app.cache_backend must be \"redis\" or \"postgres\"."
    }
    precondition {
      condition     = length(local.network.ssh_allowed_cidrs) > 0 && !contains(local.network.ssh_allowed_cidrs, "0.0.0.0/0")
      error_message = "TF_VAR_my_ip: your own address, never 0.0.0.0."
    }
    precondition {
      condition     = alltrue([for vm in local.vms : alltrue([for s in vm.services : contains(keys(local.services), s)])])
      error_message = "config.json: a VM lists a service that services.tf does not know."
    }
  }
}
