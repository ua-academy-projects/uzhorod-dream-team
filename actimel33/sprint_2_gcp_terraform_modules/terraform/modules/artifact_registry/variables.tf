variable "config" {
  description = "registry part of config.json"
  type = object({
    repository_id = string
    format        = string
    description   = string
  })
}

variable "project" {
  description = "project part of config.json"
  type = object({
    id     = string
    region = string
    labels = map(string)
  })
}
