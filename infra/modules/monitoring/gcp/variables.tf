variable "config" {
  description = "infra/config.json as a whole; this module uses prefix, tls.domain and monitoring"
  type = object({
    prefix = string
    tls    = object({ domain = string })

    monitoring = object({
      email = string

      alerts = object({
        disk_percent        = object({ severity = string, threshold = number, minutes = number })
        error_rate_percent  = object({ severity = string, threshold = number, minutes = number })
        latency_p95_seconds = object({ severity = string, threshold = number, minutes = number })
        no_snapshots        = object({ severity = string, minutes = number })
      })
    })
  })
}

# The GCP project is the provider's (envs/dev): log names and the uptime check need it
data "google_client_config" "current" {}
