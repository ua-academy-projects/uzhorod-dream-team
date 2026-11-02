variable "config" {
  description = "config.json; this module reads project and registry"
  type = object({
    project = object({
      region = string
      labels = map(string)
    })
    registry = object({
      repository_id = string
      format        = string
      description   = string
    })
  })
}
