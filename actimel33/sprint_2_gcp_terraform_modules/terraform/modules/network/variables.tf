variable "private_cidr" { type = string }
variable "management_cidr" { type = string }
variable "secure_vpc" {
  type        = string
  default     = "secure-vpc"
  description = "Secure VPC name"
}
variable "management_subnet" {
  type        = string
  description = "Name of the subnet for admin access (bastion)"
}
variable "private_network" {
  type        = string
  description = "Private network name"
}
variable "management_subnet_region" {
  type        = string
  description = "Region of the management subnet"
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
