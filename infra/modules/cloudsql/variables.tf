variable "config" {
  description = "A private Cloud SQL for PostgreSQL instance and its database"
  type = object({
    name          = string 
    region        = string
    zone          = string
    network_id    = string
    private_range = string
    version       = string
    tier          = string
    disk_size_gb  = number
    database      = string
    labels        = map(string)
  })
}
