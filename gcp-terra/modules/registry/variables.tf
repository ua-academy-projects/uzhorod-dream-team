variable "config" {
  description = "Shared configuration; this module selects its own settings."
  type = object({
    project_id = string
    region     = string
    registry   = object({ repository_id = string })
  })
}
variable "service_account_emails" { type = map(string) }
variable "publishers" { type = set(string) }
