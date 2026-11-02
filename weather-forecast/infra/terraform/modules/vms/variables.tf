variable "config" {}

variable "networks" {
  type = map(string)
}

variable "subnets" {
  type = map(string)
}

variable "service_accounts" {
  type = map(string)
}
