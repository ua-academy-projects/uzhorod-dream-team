variable "filename" {
  description = "Where to write the generated SSH config"
  type        = string
}

variable "project" {
  description = "GCP project of the bastion, for the IAP tunnel"
  type        = string
}

variable "zone" {
  description = "Zone of the bastion, for the IAP tunnel"
  type        = string
}

variable "ssh_user" {
  description = "SSH user on the VMs: the Google account with dots replaced by underscores"
  type        = string
}

variable "bastion_name" {
  description = "Name of the bastion VM"
  type        = string
}

variable "hosts" {
  description = "VMs reached through the bastion: name => internal IP"
  type        = map(string)
}
