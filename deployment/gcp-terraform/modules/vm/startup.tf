locals {
  repo_url   = var.registry.repository_url
  web_domain = var.cfg.cloudflare.domain
  google     = var.cfg.google
  images = {
    FETCHER_IMAGE   = "${local.repo_url}/fetcher:${var.cfg.application.image_version}"
    HISTORY_IMAGE   = "${local.repo_url}/history:${var.cfg.application.image_version}"
    MIGRATION_IMAGE = "${local.repo_url}/migrate:${var.cfg.application.image_version}"
    UI_IMAGE        = "${local.repo_url}/ui:${var.cfg.application.image_version}"
  }

  deploy_db_vm = !(var.cfg.cloud_sql.enabled && var.cfg.application.postgres_only)
  vms          = { for name, vm in var.cfg.vm : name => vm if name != "db" || local.deploy_db_vm }

  startup_scripts = { for name, vm in local.vms :
    name => templatefile("${path.module}/templates/startup.sh.tftpl", {
      entrypoint = vm.entrypoint
      scripts = {
        for script in setunion(vm.scripts, toset(["cloud-sql.sh"])) : script => filebase64("${path.module}/scripts/${script}")
      }
      templates = name == "ui" ? {
        "ui.conf.template" = filebase64("${path.module}/nginx/ui.conf.template")
      } : {}
      environment = merge(
        vm.env,
        var.cfg.images,
        local.images,
        vm.data_disk != null ? {
          DATA_DEVICE = "/dev/disk/by-id/google-${vm.data_disk.device_name}"
        } : {},
        {
          PROJECT_ID           = local.google.project_id
          REGISTRY_HOST        = "${local.google.region}-docker.pkg.dev"
          PRIVATE_IP           = vm.private_ip
          DB_IP                = try(var.cfg.vm.db.private_ip, "")
          DB_HOST              = var.cfg.cloud_sql.enabled ? "kyiv-air-sql-proxy" : try(var.cfg.vm.db.private_ip, "")
          REDIS_HOST           = try(var.cfg.vm.db.private_ip, "")
          RABBITMQ_HOST        = try(var.cfg.vm.db.private_ip, "")
          CLOUD_SQL            = tostring(var.cfg.cloud_sql.enabled)
          CLOUD_SQL_CONNECTION = try(var.cloud_sql.connection_name, "")
          FETCHER_IP           = var.cfg.vm.fetcher.private_ip
          HISTORY_IP           = var.cfg.vm.history.private_ip
          UI_IP                = var.cfg.vm.ui.private_ip
          UI_ORIGIN            = "https://${local.web_domain}"
          CERTBOT_DOMAIN       = local.web_domain
          POSTGRES_ONLY        = tostring(var.cfg.application.postgres_only)
          POSTGRES_DB          = var.cfg.application.database_name
          SSH_PORT             = tostring(one(var.cfg.network.firewall_rules["iap-ssh"].ports))
          READY_TIMEOUT        = tostring(var.cfg.application.ready_timeout)
          APPLICATION_ENV      = jsonencode(vm.env)
          SECRET_REFS = length(vm.secrets) > 0 ? jsonencode({
            for name in vm.secrets : name => {
              secret_id = var.secrets.secrets[name].secret_id
              version   = coalesce(var.secrets.secrets[name].version, lookup(var.cfg.secrets.versions, name, "missing"))
            }
          }) : ""
        }
      )
    })
  }
}
