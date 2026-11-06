variable "config" {
  description = "config.json; this module reads project, app (backend and database), vms (service_account_prefix and machines) and service_accounts"
  type        = any

  validation {
    condition = alltrue(flatten([
      for account in values(var.config.service_accounts) : [for role in account.roles : startswith(role, "roles/")]
    ]))
    error_message = "service_accounts.<name>.roles may only list roles/<role>."
  }
}
