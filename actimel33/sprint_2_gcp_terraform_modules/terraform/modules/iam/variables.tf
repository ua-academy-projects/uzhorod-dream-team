variable "machine_roles" {
  description = "VM name => project roles of its service account"
  type        = map(list(string))
}

variable "account_prefix" {
  description = "Prefix of the service account ID; prefix + VM name must be 6-30 characters"
  type        = string
}

variable "project_id" {
  description = "Project id"
  type        = string
}
