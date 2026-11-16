module "layout" {
  source = "../../modules/layout"
  config = jsondecode(file("${path.module}/../../config.json"))
}

module "gcp" {
  source = "../../modules/gcp"
  count  = jsondecode(file("${path.module}/../../config.json")).clouds.gcp.enabled ? 1 : 0

  project_id        = var.project_id
  config            = jsondecode(file("${path.module}/../../config.json"))
  vms               = module.layout.vms
  ssh_allowed_cidrs = ["${var.my_ip}/32"]
}
