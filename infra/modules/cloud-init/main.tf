locals {
  roles          = { for k, v in var.config.vms : k => v.bastion ? "bastion" : "app" }
  iap_range      = "35.235.240.0/20"
  admin_user     = "iss-admin"
  ssh_public_key = endswith(var.config.access.ssh_public_key, ".pub") ? trimspace(file(pathexpand(var.config.access.ssh_public_key))) : ""

  bastion  = try(one([for k, r in local.roles : k if r == "bastion"]), null)
  internal = [for k, r in local.roles : k if r == "app"]

  sshd_common = [
    "PasswordAuthentication no",
    "KbdInteractiveAuthentication no",
    "PermitRootLogin no",
    "AllowAgentForwarding no",
    "X11Forwarding no",
  ]

  bastion_sshd = join("\n", concat(["Port ${var.config.access.ssh_port}"], local.sshd_common, [
    "MaxAuthTries 3",
    "LoginGraceTime 20",
    "AllowTcpForwarding local",
    "AllowStreamLocalForwarding no",
    "PermitTunnel no",
    "GatewayPorts no",
    "AllowUsers ${join(" ", concat(["jump"], [for c in var.config.access.admin_cidrs : "${local.admin_user}@${c}"], ["*@${local.iap_range}"]))}",
    "",
  ]))

  app_sshd = join("\n", concat(local.sshd_common, [
    "AllowUsers ${local.admin_user}@${try(var.ips[local.bastion], "")} *@${local.iap_range}",
    "",
  ]))

  jump_key_options = join(",", concat(
    ["restrict", "port-forwarding"],
    [for n in local.internal : "permitopen=\"${var.ips[n]}:22\""],
    ["command=\"/bin/false\""],
  ))

  bastion_cloud_config = {
    ssh_pwauth   = false
    disable_root = true
    users = [{
      name                = "jump"
      shell               = "/bin/sh"
      lock_passwd         = true
      ssh_authorized_keys = ["${local.jump_key_options} ${local.ssh_public_key}"]
    }]
    write_files = [
      { path = "/etc/ssh/sshd_config.d/10-iss.conf", permissions = "0644", content = local.bastion_sshd },
    ]
    runcmd = [
      ["sh", "-c", "sshd -t && systemctl daemon-reload && systemctl disable --now ssh.socket && systemctl enable ssh.service && systemctl restart ssh.service"],
    ]
  }

  app_cloud_config = {
    ssh_pwauth   = false
    disable_root = true
    users = [{
      name                = local.admin_user
      shell               = "/bin/bash"
      lock_passwd         = true
      sudo                = "ALL=(ALL) NOPASSWD:ALL"
      ssh_authorized_keys = [local.ssh_public_key]
    }]
    write_files = [
      { path = "/etc/ssh/sshd_config.d/10-iss.conf", permissions = "0644", content = local.app_sshd },
    ]
    runcmd = [
      ["sh", "-c", "sshd -t && systemctl try-reload-or-restart ssh"],
    ]
  }
}
