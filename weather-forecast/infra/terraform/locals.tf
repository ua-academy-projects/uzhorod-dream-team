locals {
  vms = {
    bastion = { ip = "192.168.56.10", type = "e2-micro", disk = 10, tags = ["bastion"] }
    db      = { ip = "192.168.56.11", type = "e2-small", disk = 20, tags = ["db", "via-bastion"] }
    fetcher = { ip = "192.168.56.12", type = "e2-micro", disk = 10, tags = ["fetcher", "via-bastion"] }
    history = { ip = "192.168.56.13", type = "e2-small", disk = 12, tags = ["history", "via-bastion"] }
    ui      = { ip = "192.168.56.14", type = "e2-micro", disk = 10, tags = ["ui", "via-bastion"] }
  }

  ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))

  permit_open = join(" ", concat(
    [for name, vm in local.vms : "${vm.ip}:${var.ssh_port}" if name != "bastion"],
    ["${local.vms.ui.ip}:80"],
  ))

  ssh_socket_conf = templatefile("${path.module}/templates/ssh/socket.conf.tftpl", {
    ssh_port = var.ssh_port
  })

  metadata = {
    for name, vm in local.vms : name => merge(
      {
        ssh-keys    = "${var.ssh_user}:${local.ssh_public_key}"
        socket-conf = local.ssh_socket_conf
        sshd-conf = templatefile(
          "${path.module}/templates/ssh/${name == "bastion" ? "bastion" : "services"}.conf.tftpl",
          {
            ssh_user    = var.ssh_user
            bastion_ip  = local.vms.bastion.ip
            permit_open = local.permit_open
          },
        )
      },
      {
        startup-script = file("${path.module}/scripts/${name == "bastion" ? "bastion" : "node"}-startup.sh")
      },
      name == "bastion" ? {
        jump-pubkey = local.ssh_public_key
        nft-conf    = file("${path.module}/templates/nftables/gateway.nft")
      } : {},
    )
  }
}
