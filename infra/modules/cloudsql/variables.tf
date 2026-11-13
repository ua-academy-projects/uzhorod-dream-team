variable "name" {
  type = string
}

variable "region" {
  type = string
}

variable "zone" {
  type    = string
  default = null
}

variable "network_id" {
  type = string
}

variable "private_range" {
  type = object({
    name = string
    cidr = string
  })
}

variable "database_version" {
  type = string
}

variable "tier" {
  type = string
}

variable "edition" {
  type = string
}

variable "availability_type" {
  type = string
}

variable "disk_size_gb" {
  type = number
}

variable "deletion_protection" {
  type = bool
}

variable "backup" {
  type = object({
    enabled                = bool
    point_in_time_recovery = bool
    start_time             = string
  })
}

variable "databases" {
  type = map(object({
    name = string
    user = string
  }))
}

# keyed like `databases`; kept apart because a sensitive map cannot drive for_each
variable "passwords" {
  type      = map(string)
  sensitive = true
}
