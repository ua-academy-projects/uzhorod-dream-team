locals {
  user_data = {
    for name, vm in local.vms_with_defaults : name => "#cloud-config\n${yamlencode({
      users = vm.role == "bastion" ? [
        {
          name                = var.config.ssh.jump_user
          shell               = "/usr/sbin/nologin"
          sudo                = null
          lock_passwd         = true
          ssh_authorized_keys = tolist(values(var.config.ssh.public_keys))
        }
        ] : [
        for user, key in var.config.ssh.public_keys : {
          name                = user
          shell               = "/bin/bash"
          sudo                = "ALL=(ALL) NOPASSWD:ALL"
          lock_passwd         = true
          ssh_authorized_keys = tolist([key])
        }
      ]

      write_files = concat(
        [
          {
            path        = "/etc/systemd/system/ssh.socket.d/10-weather-port.conf"
            permissions = "0644"
            content     = templatefile("${path.module}/templates/ssh-socket.conf.tftpl", { port = var.config.ssh.port })
          },
          {
            path        = "/var/lib/weather-forecast/setup.sh"
            permissions = "0700"
            content     = file("${path.module}/scripts/setup.sh")
          },
        ],
        vm.role == "bastion" ? tolist([
          {
            path        = "/etc/ssh/sshd_config.d/10-weather.conf"
            permissions = "0644"
            content = templatefile("${path.module}/templates/sshd-bastion.conf.tftpl", {
              jump_user = var.config.ssh.jump_user
              port      = var.config.ssh.port
            })
          },
          {
            path        = "/etc/nftables.conf"
            permissions = "0644"
            content = templatefile("${path.module}/templates/gateway.nft.tftpl", {
              cidrs = join(", ", [
                for subnet in values(var.config.subnets) : subnet.cidr
                if subnet.network == var.config.subnets[vm.subnet].network
              ])
            })
          },
          {
            path        = "/etc/sysctl.d/90-weather-gateway.conf"
            permissions = "0644"
            content     = "net.ipv4.ip_forward = 1\n"
          },
          ]) : tolist([
          {
            path        = "/etc/ssh/sshd_config.d/10-weather.conf"
            permissions = "0644"
            content = templatefile("${path.module}/templates/sshd-node.conf.tftpl", {
              allow_users = join(" ", [
                for user in keys(var.config.ssh.public_keys) : "${user}@${one([
                  for bastion in values(local.vms_with_defaults) : bastion.ip
                  if bastion.role == "bastion" && var.config.subnets[bastion.subnet].network == var.config.subnets[vm.subnet].network
                ])}"
              ])
            })
          },
        ]),
      )

      runcmd = [["/var/lib/weather-forecast/setup.sh", vm.role]]
    })}"
  }
}
