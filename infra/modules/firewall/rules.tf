locals {
  bastions    = [for name, vm in var.instances : name if vm.bastion]
  vm_services = { for name, vm in var.instances : name => coalesce(vm.services, [name]) }

  # one rule per service that has ports and someone allowed to reach them, aimed at the instances running it
  service_rules = {
    for name, svc in var.services : "allow-${name}" => {
      ports       = [for p in svc.ports : tostring(p)]
      target_tags = [for vm, running in local.vm_services : vm if contains(running, name)]
      source_tags = svc.allow_from
      # "MY_IP" = whoever runs terraform, "CLOUDFLARE" = the proxy's address ranges, anything else is a CIDR
      source_ranges = flatten([for r in svc.public_from : r == "MY_IP" ? [var.my_ip] : r == "CLOUDFLARE" ? var.cloudflare_ranges : [r]])
    } if length(svc.ports) > 0 && length(concat(svc.allow_from, svc.public_from)) > 0
  }

  ssh_rules = merge(
    {
      for name, rule in {
        allow-ssh-bastion = {
          ports         = ["22"]
          target_tags   = local.bastions
          source_tags   = []
          source_ranges = [for r in var.ssh.bastion_from : r == "MY_IP" ? var.my_ip : r]
        }
        allow-ssh-from-bastion = {
          ports         = ["22"]
          target_tags   = [for name in keys(var.instances) : name if !contains(local.bastions, name)]
          source_tags   = local.bastions
          source_ranges = []
        }
      } : name => rule if length(local.bastions) > 0
    },
    {
      for name, rule in {
        allow-ssh-from-iap = {
          ports         = ["22"]
          target_tags   = keys(var.instances)
          source_tags   = []
          source_ranges = ["35.235.240.0/20"] # Google's IAP TCP forwarding range
        }
      } : name => rule if var.ssh.iap
    },
  )

  # a rule without target tags would apply to every instance, so rules with no target are dropped
  rules = { for name, rule in merge(local.service_rules, local.ssh_rules) : name => rule if length(rule.target_tags) > 0 }
}
