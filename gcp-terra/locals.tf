# Relative paths are resolved from the root module, not the shell cwd.
locals {
  config     = jsondecode(file(startswith(var.config_file, "/") ? var.config_file : "${path.root}/${var.config_file}"))
  monitoring = jsondecode(file(startswith(var.monitoring_file, "/") ? var.monitoring_file : "${path.root}/${var.monitoring_file}")).monitoring
}
