module "logging" {
  source = "./modules/logging"
}

module "alerts" {
  source = "./modules/alerts"

  config = var.config
  promql = module.logging.promql

  depends_on = [module.logging]
}

module "dashboard" {
  source = "./modules/dashboard"

  config       = var.config
  log_filters  = module.logging.log_filters
  promql       = module.logging.promql
  filters      = module.alerts.filters
  policy_names = module.alerts.policy_names
}
