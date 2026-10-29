
# network
module "network" {
  source = "../../modules/network"
  config = {
    name              = "${local.project.prefix}-vpc"
    region            = local.project.region
    subnet_cidr       = local.network.subnet_cidr
    ssh_allowed_cidrs = local.network.ssh_allowed_cidrs
    internal_ports    = local.internal_ports # from services.tf
    bastion_tag       = "bastion"
  }
}

# code
resource "google_storage_bucket" "code" {
  name                        = "${local.project.id}-${local.project.prefix}-code"
  location                    = upper(local.project.region)
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true
  labels                      = local.labels
}

data "archive_file" "code" {
  type        = "zip"
  source_dir  = "${path.module}/../../../services"
  output_path = "${path.module}/.build/services.zip"
  excludes    = ["ui/node_modules", "ui/dist"]
}

# the file name carries the content hash: new code = new name = the VMs see a change
resource "google_storage_bucket_object" "code" {
  name   = "services-${data.archive_file.code.output_md5}.zip"
  bucket = google_storage_bucket.code.name
  source = data.archive_file.code.output_path
}

# VMs
locals {
  user_key     = trimspace(file(pathexpand(local.ssh.user_public_key_file)))
  internal_key = trimspace(file(pathexpand(local.ssh.internal_public_key_file)))
}

module "vm" {
  source   = "../../modules/vm"
  for_each = toset(keys(local.vms))

  config = {
    name          = "${local.project.prefix}-${each.key}"
    region        = local.project.region
    zone          = local.project.zone
    machine_type  = local.vms[each.key].machine_type
    disk_size_gb  = local.vms[each.key].disk_size_gb
    image         = local.vms[each.key].image
    subnetwork_id = module.network.subnetwork_id
    internal_ip   = local.ip[each.key]
    public        = each.key == local.bastion
    tags          = each.key == local.bastion ? ["bastion"] : []
    labels        = merge(local.labels, { vm = each.key })
  }

  # everything the VM needs to know; startup.sh reads it at every boot
  metadata = merge(
    {
      ssh-keys               = "${local.ssh.user}:${each.key == local.bastion ? local.user_key : local.internal_key}"
      block-project-ssh-keys = "true"
      enable-oslogin         = "FALSE"

      startup-script = file("${path.module}/startup.sh")
      ssh-user       = local.ssh.user
    },
    # VMs with services
    {
      for k, v in {
        code    = "gs://${google_storage_bucket.code.name}/${google_storage_bucket_object.code.name}"
        compose = local.compose_yaml[each.key]
        secrets = join(" ", [for name in local.vm_secrets[each.key] : "${name}=${local.secret_ids[name]}"])
      } : k => v if length(local.vms[each.key].services) > 0
    },

    { for k, v in { ssh-key-secret = local.ssh_key_secret } : k => v if each.key == local.bastion },
  )

  depends_on = [module.network]
}

resource "google_storage_bucket_iam_member" "code" {
  for_each = module.vm
  bucket   = google_storage_bucket.code.name
  role     = "roles/storage.objectViewer"
  member   = each.value.member
}

resource "google_project_iam_member" "log_writer" {
  for_each = toset([for name, vm in local.vms : name if vm.cloud_logging])
  project  = local.project.id
  role     = "roles/logging.logWriter"
  member   = module.vm[each.key].member
}

# secrets
module "secrets" {
  source = "../../modules/secrets"
  config = {
    readers = local.secret_readers # from services.tf
    members = { for name, vm in module.vm : name => vm.member }
    labels  = local.labels
  }
}
