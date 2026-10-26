variable "project_id" {
  type = string
}

variable "region" {
  default = "europe-central2"
}

variable "zone" {
  default = "europe-central2-a"
}

variable "prefix" {
  default = "tf-weather"
}

variable "my_ip_cidr" {
  type        = string
  description = "Public IP with /32"
}

variable "ssh_port" {
  type = number

  validation {
    condition     = var.ssh_port >= 1024 && var.ssh_port <= 65535
    error_message = "ssh_port must be between 1024 and 65535"
  }
}

variable "ssh_user" {
  type = string
}

variable "ssh_public_key_path" {
  default = "~/.ssh/weather_vm.pub"
}
