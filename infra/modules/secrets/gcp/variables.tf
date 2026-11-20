variable "config" {
  description = "infra/config.json as a whole; this module uses prefix"
  type = object({
    prefix = string
  })
}

variable "secrets" {
  description = "The secrets to make in GCP, by their config.json names (e.g. db-password)"
  type        = list(string)
}
