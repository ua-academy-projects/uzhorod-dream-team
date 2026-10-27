variable "private_cidr" { type = string }
variable "edge_cidr" { type = string }
variable "secure_vpc" {
  type        = string
  default     = "secure-vpc"
  description = "Secure VPC name"
}
variable "edge_network" {
  type        = string
  description = "Edge network name"
}
variable "private_network" {
  type        = string
  description = "Private network name"
}
variable "edge_subnet_region" {
  type        = string
  description = "Region of the edge network"
  default     = "europe-central2"
}
variable "private_subnet_region" {
  type        = string
  description = "Region of the private network"
  default     = "europe-central2"
}
variable "nat_router_name" {
  type        = string
  description = "Cloud router name"
  default     = "nat-router"
}
variable "nat_router_region" {
  type        = string
  description = "Cloud router region"
  default     = "europe-central2"
}
