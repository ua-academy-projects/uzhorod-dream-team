variable "name" {
  description = "Name of the VM"
  type        = string
}

variable "machine_type" {
  description = "Instance type, (e2-micro, e2-small)"
  type        = string
  default     = "e2-micro"
}

variable "zone" {
  description = "Zone GCP e.g. (europe-west3-a)"
  type        = string
}

variable "subnetwork" {
  description = "Selflink (self_link) or subnet name"
  type        = string
}

variable "image" {
  description = "Image"
  type        = string
  default     = "debian-cloud/debian-11"
}

variable "disc_size" {
  description = "Disc size in GB"
  type        = number
  default     = 10
}

variable "disc_type" {
  description = "Disc type ( pd-standard, pd-ssd or pd-balanced)"
  type        = string
  default     = "pd-balanced"
}

variable "has_public_ip" {
  description = "If publick IP-required"
  type        = bool
  default     = false
}

variable "labels" {
  description = "Recource Labels"
  type        = map(string)
  default     = {}
}

variable "network_tags" {
  description = "Net Tags for firewall rules"
  type        = list(string)
  default     = []
}

variable "startup_script" {
  description = "Settings script on start VM"
  type        = string
  default     = null
}

variable "attached_disk_id" {
  description = "ID or self_link external disc"
  type        = string
  default     = null
}

variable "attached_disk_device_name" {
  description = "Device name of the attached disc inside the VM"
  type        = string
  default     = "data-disk"
}
