variable "config" {
  description = "One service account per VM, each with exactly the project roles listed for it"
  type = object({
    project_id = string
    prefix     = string
    vms = map(object({
      roles         = optional(list(string), [])
      cloud_logging = optional(bool, false)
    }))
  })

  validation {
    condition     = alltrue([for vm in var.config.vms : !vm.cloud_logging || contains(vm.roles, "roles/logging.logWriter")])
    error_message = "config.json: a VM with \"cloud_logging\": true needs \"roles/logging.logWriter\" in its \"roles\"."
  }
}