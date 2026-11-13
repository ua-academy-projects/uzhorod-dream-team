variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

# access: what a VM may reach beyond logs and metrics
#   "artifacts" read the artifacts bucket (binaries, frontend files)
#   "cloudsql"  roles/cloudsql.client
variable "instances" {
  type = map(object({
    access = optional(list(string), [])
  }))

  validation {
    condition     = alltrue([for i in values(var.instances) : alltrue([for a in i.access : contains(["artifacts", "cloudsql"], a)])])
    error_message = "access may only contain \"artifacts\" and \"cloudsql\"."
  }
}

# who may impersonate the ansible service account, as an IAM member: user:you@example.com
variable "operator_member" {
  type = string

  validation {
    condition     = can(regex("^(user|serviceAccount|group):", var.operator_member))
    error_message = "operator_member must look like user:you@example.com (set by terraform.env)."
  }
}
