variable "config" {
  description = "config.json; this module reads project and cloud_sql"
  type = object({
    project = object({
      id     = string
      region = string
      labels = map(string)
    })
    cloud_sql = object({
      name                = string
      database_version    = string
      edition             = string
      tier                = string
      availability_type   = string
      disk_size           = number
      disk_type           = string
      deletion_protection = bool
      database            = string
      user                = string
      password_secret     = string
      endpoint            = string
    })
  })

  validation {
    condition     = contains(keys(var.secret_versions), var.config.cloud_sql.password_secret)
    error_message = "cloud_sql.password_secret must be a secret in the secrets part of config.json."
  }
}

variable "network" {
  description = "The VPC (from the network module)"
  type        = string
}

variable "subnets" {
  description = "Subnet role => self_link (from the network module); the endpoint goes to private"
  type        = map(string)
}

variable "secret_versions" {
  description = "Secret ID => its current version (from the secrets module)"
  type        = map(string)
}
