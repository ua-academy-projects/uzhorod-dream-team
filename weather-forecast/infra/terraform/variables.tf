variable "project_id" {
  type        = string
  description = "GCP project ID"
}

variable "alert_email" {
  type        = string
  description = "Email for monitoring alerts"
}

variable "config_path" {
  type    = string
  default = "~/.config/weather-forecast/deployment.json"
}
