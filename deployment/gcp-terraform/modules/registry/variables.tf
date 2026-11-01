variable "cfg" {
  type = object({
    registry = object({
      id          = optional(string, "kyiv-air")
      description = optional(string, "Kyiv Air container images")
    })
    google = object({
      project_id = string
      region     = optional(string, "us-central1")
    })
  })
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
