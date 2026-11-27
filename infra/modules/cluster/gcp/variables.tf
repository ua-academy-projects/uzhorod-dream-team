variable "config" {
  description = "infra/config.json as a whole; this module uses prefix"
  type = object({
    prefix = string
  })
}

variable "region" {
  type = string
}

variable "zone" {
  description = "The zone of the VMs (an unmanaged instance group is zonal)"
  type        = string
}

variable "subnet_cidr" {
  type = string
}

variable "network_id" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "api_nlb_ip_index" {
  description = "The index of the API's network load balancer's address in the subnet (k3s.api_nlb_ip_index): the API's private address"
  type        = number
}

variable "control_plane" {
  description = "control plane node name => its instance (self link)"
  type        = map(string)
}
