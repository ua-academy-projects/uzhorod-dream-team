variable "project_id" {
  description = "Google Cloud Project ID"
  type        = string
}

variable "region" {
  description = "Google Cloud region"
  type        = string
}

variable "zone" {
  description = "Google Cloud zone"
  type        = string
}

variable "machine_type" {
  description = "Default VM machine type"
  type        = string
  default     = "e2-small"
}

variable "machine_size" {
  description = "Default VM disk size in GB"
  type        = number
  default     = 15
}

variable "boot_image" {
  description = "Default VM image"
  type        = string
  default     = "ubuntu-os-cloud/ubuntu-2404-lts"
}

variable "admin_ip_cidr" {
  type        = string
  description = "Allowed public IP for Bastion SSH"
}