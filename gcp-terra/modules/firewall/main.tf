locals {
  config = var.config.firewall
  ports  = merge(var.config.ports, { bastion_ssh = var.config.compute.instances.bastion.startup.ssh_port })
  rules = [for rule in local.config.rules : merge(rule, {
    enabled = rule.enabled && (
      rule.name == "allow-app-postgres" ? var.config.database.provider == "container" :
      contains(["allow-app-rabbitmq", "allow-ui-redis"], rule.name) ? var.config.compute.application.app_backend == "hybrid" : true
    )
  })]
}

resource "google_compute_firewall" "rules" {
  for_each  = { for rule in local.rules : rule.name => rule if rule.enabled }
  name      = each.value.name
  network   = var.network_id
  direction = each.value.direction
  priority  = each.value.priority

  source_ranges      = each.value.source_ranges
  destination_ranges = each.value.destination_ranges
  source_tags        = length(each.value.source_tags) > 0 ? each.value.source_tags : null
  target_tags        = each.value.target_tags

  dynamic "allow" {
    for_each = each.value.allowed
    content {
      protocol = allow.value.protocol
      ports    = concat(allow.value.ports, [for key in allow.value.port_keys : tostring(local.ports[key])])
    }
  }
  dynamic "deny" {
    for_each = each.value.denied
    content {
      protocol = deny.value.protocol
      ports    = deny.value.ports
    }
  }
}

