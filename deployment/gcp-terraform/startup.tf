locals {
  application_images = {
    FETCHER_IMAGE   = "${module.registry.repository_url}/fetcher:${local.cfg.application.image_version}"
    HISTORY_IMAGE   = "${module.registry.repository_url}/history:${local.cfg.application.image_version}"
    MIGRATION_IMAGE = "${module.registry.repository_url}/migrate:${local.cfg.application.image_version}"
    UI_IMAGE        = "${module.registry.repository_url}/ui:${local.cfg.application.image_version}"
  }

  startup_scripts = {
    for role, vm in local.cfg.vm :
    role => templatefile("${path.module}/templates/startup.sh.tftpl", {
      entrypoint = vm.entrypoint
      scripts = {
        for script in vm.scripts : script => filebase64("${path.module}/scripts/${script}")
      }
      templates = role == "ui" ? {
        "ui.conf.template" = filebase64("${path.module}/nginx/ui.conf.template")
      } : {}
      environment = merge(vm.env, local.cfg.images, local.application_images, {
        PROJECT_ID      = local.cfg.google.project_id
        REGISTRY_HOST   = "${local.cfg.google.region}-docker.pkg.dev"
        PRIVATE_IP      = vm.private_ip
        DB_IP           = local.cfg.vm.db.private_ip
        FETCHER_IP      = local.cfg.vm.fetcher.private_ip
        HISTORY_IP      = local.cfg.vm.history.private_ip
        UI_IP           = local.cfg.vm.ui.private_ip
        UI_ORIGIN       = "https://${local.cfg.cloudflare.domain}"
        CERTBOT_DOMAIN  = local.cfg.cloudflare.domain
        POSTGRES_ONLY   = tostring(local.cfg.application.postgres_only)
        POSTGRES_DB     = local.cfg.application.database_name
        SSH_PORT        = tostring(one(local.cfg.network.firewall_rules["iap-ssh"].ports))
        READY_TIMEOUT   = tostring(local.cfg.application.ready_timeout)
        APPLICATION_ENV = jsonencode(vm.env)
        SECRET_REFS = jsonencode({
          for name in vm.secrets : name => {
            secret_id = module.secrets.secrets[name].secret_id
            version   = coalesce(module.secrets.secrets[name].version, lookup(local.cfg.secrets.versions, name, "missing"))
          }
        })
      })
    })
  }
}
