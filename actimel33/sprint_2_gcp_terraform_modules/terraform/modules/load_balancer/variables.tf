variable "name" {
  description = "Prefix of the names of all load balancer resources"
  type        = string
}

variable "zone" {
  description = "Zone of the backend VM"
  type        = string
}

variable "instance_id" {
  description = "ID of the VM that receives the traffic"
  type        = string
}

variable "port" {
  description = "Port the application listens on inside the VM"
  type        = number
}

variable "health_check_path" {
  description = "Path the health check requests, it must answer 200"
  type        = string
  default     = "/"
}

variable "domain_name" {
  description = "Domain of the site, the certificate is issued for it"
  type        = string
}
