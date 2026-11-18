module "gcp" {
  source = "./gcp"
  count  = var.config.default_cloud == "gcp" ? 1 : 0

  config = var.config
}
