variable "repository_id" {
  description = "Name of the repository"
  type        = string
}

variable "location" {
  description = "Region of the repository"
  type        = string
}

variable "format" {
  description = "Repository format (DOCKER, NPM, PYTHON, ...)"
  type        = string
  default     = "DOCKER"
}

variable "description" {
  description = "Description of the repository"
  type        = string
  default     = null
}

variable "labels" {
  description = "Resource labels"
  type        = map(string)
  default     = {}
}

variable "reader_emails" {
  description = "VM name => email of its service account, allowed to pull images"
  type        = map(string)
  default     = {}
}
