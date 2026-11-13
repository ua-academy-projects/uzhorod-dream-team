# ssh config with short aliases (ssh fetcher, ssh database, ...) for the VMs in the private network, reached through the bastion.
#   terraform output -raw ssh_config > ~/.ssh/osm_config      # then add "Include ~/.ssh/osm_config" to ~/.ssh/config

variable "ssh_user" {
  type        = string
  description = "OS Login username (see: gcloud compute os-login describe-profile), same as remote_user in my-ansible/ansible.cfg"
}

variable "ssh_identity_file" {
  type    = string
  default = "~/.ssh/id_ed25519"
}

locals {
  bastions = { for k, v in local.config.instances : k => v if try(v.bastion, false) }

  # every non-bastion VM is reached through the (single) bastion by its internal address from config.json
  private_hosts = { for k, v in local.config.instances : k => v if !try(v.bastion, false) }
}

output "ssh_config" {
  value = templatefile("${path.module}/ssh_config.tftpl", {
    user          = var.ssh_user
    identity_file = var.ssh_identity_file
    bastions      = local.bastions
    bastion_name  = keys(local.bastions)[0]
    public_ips    = module.instances.public_ips
    private_hosts = local.private_hosts
    all_hosts     = keys(local.config.instances)
  })
}
