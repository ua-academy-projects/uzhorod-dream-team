variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "repository_id" {
  type = string
}

variable "service_account_emails" {
  type = map(string)
}

variable "publishers" {
  type = set(string)
}
