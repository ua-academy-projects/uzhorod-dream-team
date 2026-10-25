locals {
  private_cidr = "192.168.77.0/24"
  edge_cidr    = "192.168.78.0/24"
  iap_cidr     = "35.235.240.0/20" # the Console SSH button
  # Proxies and health checks of the global external Application Load Balancer.
  lb_source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]

  # One VM per role. The bastion and the UI get an edge interface.
  machines = {
    bastion = { type = "e2-micro", private_ip = "192.168.77.5", edge_ip = "192.168.78.5" }
    db      = { type = "e2-small", private_ip = "192.168.77.10", edge_ip = null }
    fetcher = { type = "e2-small", private_ip = "192.168.77.11", edge_ip = null }
    history = { type = "e2-small", private_ip = "192.168.77.12", edge_ip = null }
    ui      = { type = "e2-small", private_ip = "192.168.77.13", edge_ip = "192.168.78.13" }
  }

  # Everything behind the bastion.
  services = toset(["db", "fetcher", "history", "ui"])

  ip = { for name, machine in local.machines : name => machine.private_ip }

  ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))

  # jump may only forward to port 22 of the services: no shell, no other ports.
  jump_authorized_key = format(
    "restrict,port-forwarding,%s,command=\"/bin/false\" %s",
    join(",", [for name in sort(tolist(local.services)) : "permitopen=\"${local.ip[name]}:22\""]),
    local.ssh_public_key,
  )
}
