variable "name" {
  description = "Name of the disk"
  type        = string
}

variable "zone" {
  description = "Zone of the disk, must match the zone of the VM it is attached to"
  type        = string
}

variable "size" {
  description = "Disk size in GB"
  type        = number
  default     = 10
}

variable "type" {
  description = "Disk type (pd-standard, pd-balanced or pd-ssd)"
  type        = string
  default     = "pd-standard"
}

variable "labels" {
  description = "Resource labels"
  type        = map(string)
  default     = {}
}
