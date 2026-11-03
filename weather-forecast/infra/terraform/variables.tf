variable "project_id" {
  type        = string
  description = "GCP project ID"
}

variable "my_ip_cidr" {
  type = string
}

variable "config_path" {
  type    = string
  default = "~/.config/weather-forecast/deployment.json"
}
