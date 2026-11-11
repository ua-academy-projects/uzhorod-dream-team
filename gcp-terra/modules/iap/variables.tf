variable "config" {
  description = "Shared configuration; this module selects its own settings."
  type = object({
    project_id = string
    zone       = string
    compute    = object({ instances = object({ bastion = object({ name = string, startup = object({ ssh_port = number }) }) }) })
  })
}
variable "members" { type = set(string) }
