variable "project" {
  description = "The GCP project to create, and where everything lives"
  type = object({
    id              = string
    name            = optional(string) 
    billing_account = string 
    region          = string 
    zone            = string 
  })
}

variable "my_ip" {
  description = "Your public IPv4: only it may SSH to the bastion (curl ifconfig.me)"
  type        = string

  validation {
    condition     = can(cidrhost("${var.my_ip}/32", 0))
    error_message = "my_ip must be one IPv4 address, e.g. 203.0.113.7 (without /32)."
  }
}

variable "output_dir" {
  description = "Where the key and terraform.env are written: OUTSIDE the repository"
  type        = string
  default     = "~/.config/citybikes"
}
