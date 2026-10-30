variable "config" {
  description = "ssh part of config.json: OS Login user and the name of the bastion VM"
  type = object({
    user    = string
    bastion = string
  })
}

variable "project" {
  description = "project part of config.json"
  type = object({
    id     = string
    region = string
    labels = map(string)
  })
}

variable "instances" {
  description = "VMs from the vms module: name => id, zone, private_ip and port"
  type = map(object({
    id         = string
    zone       = string
    private_ip = string
    port       = number
  }))
}
