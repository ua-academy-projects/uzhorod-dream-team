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
  type    = number
  default = 22
}

variable "ssh_user" {
  type = string
}

variable "ssh_public_key_path" {
  default = "~/.ssh/weather_vm.pub"
}
