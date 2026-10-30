variable "project_id" {
  type        = string
  description = "GCP project_id"
}

variable "repository" {
  type = object({
    id          = optional(string, "kyiv-air")
    description = optional(string, "Kyiv Air container images")
    location    = optional(string, "us-central1")
  })
  description = "Artifact registry repository config"
}

variable "readers" {
  type        = map(object({ email = string }))
  description = "Stable names mapped to IAM members allowed to pull images."
  default     = {}
}

variable "writers" {
  type        = map(object({ email = string }))
  description = "Stable names mapped to IAM members allowed to push images."
  default     = {}
}
