variable "config" {
  description = "One VM"
  type = object({
    name          = string 
    region        = string
    zone          = string
    machine_type  = string
    disk_size_gb  = number
    image         = string
    subnetwork_id = string
    internal_ip   = string       
    public        = bool         
    tags          = list(string) # network tags: firewall rules target them
    labels        = map(string)
  })
}

variable "metadata" {
  description = "Instance metadata: ssh-keys, startup-script and what the startup script reads"
  type        = map(string)
}
