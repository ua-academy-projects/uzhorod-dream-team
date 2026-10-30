locals {
  application_images = {
    FETCHER_IMAGE   = "${var.registry_url}/fetcher:${var.application.image_version}"
    HISTORY_IMAGE   = "${var.registry_url}/history:${var.application.image_version}"
    MIGRATION_IMAGE = "${var.registry_url}/migrate:${var.application.image_version}"
    UI_IMAGE        = "${var.registry_url}/ui:${var.application.image_version}"
  }

  startup_script = templatefile("${path.module}/templates/startup.sh.tftpl", {
    entrypoint = var.machine.entrypoint
    scripts = {
      for script in var.machine.scripts : script => filebase64("${path.module}/scripts/${script}")
    }
    templates = var.machine.name == "ui" ? {
      "ui.conf.template" = filebase64("${path.module}/nginx/ui.conf.template")
    } : {}
    environment = merge(
      var.machine.env,
      var.images,
      local.application_images,
      var.machine.data_disk != null ? {
        DATA_DEVICE = "/dev/disk/by-id/google-${var.machine.data_disk.device_name}"
      } : {},
      {
        PROJECT_ID      = var.google.project_id
        REGISTRY_HOST   = "${var.google.region}-docker.pkg.dev"
        PRIVATE_IP      = var.network.private_ip
        DB_IP           = var.vms.db.private_ip
        FETCHER_IP      = var.vms.fetcher.private_ip
        HISTORY_IP      = var.vms.history.private_ip
        UI_IP           = var.vms.ui.private_ip
        UI_ORIGIN       = "https://${var.domain}"
        CERTBOT_DOMAIN  = var.domain
        POSTGRES_ONLY   = tostring(var.application.postgres_only)
        POSTGRES_DB     = var.application.database_name
        SSH_PORT        = tostring(one(var.network.firewall_rules["iap-ssh"].ports))
        READY_TIMEOUT   = tostring(var.application.ready_timeout)
        APPLICATION_ENV = jsonencode(var.machine.env)
        SECRET_REFS = length(var.machine.secrets) > 0 ? jsonencode({
          for name in var.machine.secrets : name => {
            secret_id = var.secrets.secrets[name].secret_id
            version   = coalesce(var.secrets.secrets[name].version, lookup(var.secrets.versions, name, "missing"))
          }
        }) : ""
      }
    )
  })
}
