variable "config" {}

variable "my_ip_cidr" {
  type = string
}

variable "networks" {
  type = map(string)
}
