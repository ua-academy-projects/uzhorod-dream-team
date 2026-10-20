BRIDGE = "Intel(R) Wi-Fi 6 AX200 160MHz"
PUBKEY = File.expand_path("~/.ssh/bastion_key.pub")

Vagrant.configure("2") do |config|
  config.vm.box = "ubuntu/jammy64"

  vms = [
    { name: "postgres", ip: "192.168.56.13", folder: "./DataFetcher/postgres",
      provision: "./provision/postgres.sh", memory: 2048, cpus: 1 },
    { name: "fetcher", ip: "192.168.56.11", folder: "./DataFetcher/fetcher",
      provision: "./provision/fetcher.sh", memory: 1024, cpus: 1 },
    { name: "history", ip: "192.168.56.12", folder: "./DataFetcher/history",
      provision: "./provision/history.sh", memory: 1024, cpus: 1 },
    { name: "ui", ip: "192.168.56.14", folder: "./DataFetcher/ui",
      provision: "./provision/ui.sh", memory: 1024, cpus: 1, public: true },
    { name: "bastion", ip: "192.168.56.10", folder: nil,
      provision: "./provision/bastion.sh", memory: 512, cpus: 1, public: true }
  ]

  vms.each do |vm|
    config.vm.define vm[:name] do |machine|
      machine.vm.hostname = vm[:name]

      machine.vm.network "public_network", bridge: BRIDGE if vm[:public]

      machine.vm.network "private_network",
        ip: vm[:ip],
        virtualbox__intnet: "internal"

      if vm[:name] == "bastion"
        machine.vm.network "forwarded_port",
          guest: 22, host: 2225, host_ip: "127.0.0.1", id: "ssh-bastion"
      end

      if vm[:name] == "bastion"
        machine.vm.synced_folder ".", "/vagrant", disabled: true
      else
        machine.vm.synced_folder vm[:folder], "/vagrant"
        machine.vm.synced_folder "./DataFetcher", "/project"
      end

      if File.exist?(PUBKEY)
        machine.vm.provision "shell", name: "ssh-key", args: [File.read(PUBKEY).strip],
          inline: <<-SHELL
            install -d -m 700 -o vagrant -g vagrant /home/vagrant/.ssh
            grep -qxF "$1" /home/vagrant/.ssh/authorized_keys || echo "$1" >> /home/vagrant/.ssh/authorized_keys
          SHELL
      end

      if vm[:name] == "ui"
        machine.vm.provision "shell", name: "ui-ssh-lockdown", inline: <<-SHELL
          BR_IF=$(ip -o -4 addr show | awk '$4 !~ /^(127\\.|10\\.0\\.2\\.|192\\.168\\.56\\.)/ {print $2}' | head -1)
          if [ -n "$BR_IF" ]; then
            ufw default allow incoming
            ufw deny in on "$BR_IF" to any port 22 proto tcp
            ufw --force enable
          fi
        SHELL
      end

      machine.vm.provision "shell", path: vm[:provision] if vm[:provision]

      machine.vm.provider "virtualbox" do |vb|
        vb.gui = false
        vb.memory = vm[:memory]
        vb.cpus = vm[:cpus]
      end
    end
  end
end
