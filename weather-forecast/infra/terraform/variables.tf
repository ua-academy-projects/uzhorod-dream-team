variable "project_id" {
  type        = string
  description = "GCP project ID"
}

variable "config_path" {
  type    = string
  default = "~/.config/weather-forecast/deployment.json"
}
