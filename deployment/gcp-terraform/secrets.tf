ephemeral "random_password" "service" {
  for_each = local.cfg.secrets.passwords

  length  = 32
  special = false
}

module "secrets" {
  source = "./modules/secrets/"

  project_id = local.cfg.google.project_id
  vm_access = {
    for vm, acc in google_service_account.vm :
    vm => {
      email   = acc.email
      secrets = local.cfg.vm[vm].secrets
    }
  }
  revisions = var.secret_revisions
  payloads = merge(var.secret_payloads, {
    for pwd in local.cfg.secrets.passwords :
    pwd => ephemeral.random_password.service[pwd].result
  })

  secrets_to_set = setunion(
    toset(local.cfg.secrets.passwords),
    toset(keys(var.secret_revisions)),
  )

  depends_on = [google_project_service.required["secret"]]
}
