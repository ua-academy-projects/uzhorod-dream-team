variable "project_id" {
  type = string
}

variable "zone" {
  type = string
}

variable "instance_name" {
  type = string
}

variable "ssh_port" {
  type = number
}

variable "members" {
  type = set(string)
}
