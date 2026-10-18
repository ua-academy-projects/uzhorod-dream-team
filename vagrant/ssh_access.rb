SSH_PUBKEY = "#{ROOT}/.vagrant/iss_tracker_ed25519.pub"
VAGRANT_NAT_IP = "10.0.2.2"

def wsl_ssh(*args)
  system("wsl.exe", "--cd", ROOT, "-e", "bash", "scripts/host/wsl_ssh.sh", *args) ||
    warn("WSL SSH setup failed: wsl_ssh.sh #{args.join(' ')}")
end

wsl_ssh("key") unless File.exist?(SSH_PUBKEY)

def host_only_gateway
  ip_of(BASTION).sub(/\.\d+\z/, ".1")
end

def provision_ssh_access(node, vm)
  bastion = vm[:name] == BASTION

  if File.exist?(SSH_PUBKEY)
    key = File.read(SSH_PUBKEY).strip
    if bastion
      node.vm.provision "bastion", type: "shell", path: "scripts/provision/bastion.sh", env: {
        "SSH_PUBLIC_KEY" => key,
        "PERMIT_OPEN" => VMS.reject { |v| v[:name] == BASTION }.map { |v| "#{ip_of(v[:name])}:22" }.join(" "),
        "VAGRANT_NAT_IP" => VAGRANT_NAT_IP,
        "COLLECTOR_IP" => ip_of(LOG_COLLECTOR),
        "TRUSTED_IP" => host_only_gateway
      }
    else
      node.vm.provision "admin", type: "shell", path: "scripts/provision/admin.sh", env: {
        "SSH_PUBLIC_KEY" => key,
        "ADMIN_USER" => ADMIN_USER,
        "BASTION_IP" => ip_of(BASTION),
        "VAGRANT_NAT_IP" => VAGRANT_NAT_IP,
        "COLLECTOR_IP" => ip_of(LOG_COLLECTOR)
      }
    end
  end

  ssh_user = bastion ? "jump" : ADMIN_USER
  proxy = bastion ? [] : [BASTION]
  node.trigger.after [:up, :reload] do |t|
    t.info = "Configuring 'ssh #{vm[:name]}' in WSL"
    t.ruby { wsl_ssh("host", vm[:name], ip_of(vm[:name]), ssh_user, *proxy) }
  end
  node.trigger.after :destroy do |t|
    t.ruby { wsl_ssh("remove", vm[:name], ip_of(vm[:name])) }
  end
end
