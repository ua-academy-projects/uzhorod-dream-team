variable "project_id" {
  type = string
}

variable "location" {
  type = string
}

variable "repository_id" {
  type    = string
  default = "kyiv-air"
}

variable "description" {
  type    = string
  default = "Kyiv Air container images"
}

variable "readers" {
  type        = map(string)
  description = "Stable names mapped to IAM members allowed to pull images."
  default     = {}
}

variable "writers" {
  type        = map(string)
  description = "Stable names mapped to IAM members allowed to push images."
  default     = {}
}
