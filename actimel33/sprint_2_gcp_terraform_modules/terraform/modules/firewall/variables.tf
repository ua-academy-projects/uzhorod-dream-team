variable "network_name" {
  description = "Name of the VPC network, to which rules are attached (from outputs network module)"
  type        = string
}

variable "iap_cidr" {
  description = "IP range for tunels Google Cloud IAP"
  type        = string
}

variable "edge_cidr" {
  description = "Range of edge subnetwork (from networks in JSON)"
  type        = string
}

variable "lb_source_ranges" {
  description = "Range of  IP-adresses for Google Cloud Load Balancer (from JSON)"
  type        = list(string)
}
