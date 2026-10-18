require_relative "vagrant/env"
require_relative "vagrant/ssh_access"
require_relative "vagrant/app"
require_relative "vagrant/logging"

BASTION = "iss-jump"
ADMIN_USER = "iss-admin"
DATABASE = "iss-db"
LOG_COLLECTOR = "iss-db"

VMS = [
  { name: "iss-jump",    ip: "JUMP_IP",    memory: 512,  public: true },
  { name: "iss-db",      ip: "DB_IP",      memory: 2048, src: "services/postgres" },
  { name: "iss-history", ip: "HISTORY_IP", memory: 1024, src: "services/history" },
  { name: "iss-fetcher", ip: "FETCHER_IP", memory: 1024, src: "services/fetcher" },
  { name: "iss-ui",      ip: "UI_IP",      memory: 1024, src: "services/ui", public: true }
].freeze

Vagrant.configure("2") do |config|
  config.vm.box = "ubuntu/jammy64"
  config.vm.boot_timeout = 600
  config.vm.synced_folder ".", "/vagrant", disabled: true

  VMS.each do |vm|
    config.vm.define vm[:name] do |node|
      node.vm.hostname = vm[:name]
      node.vm.network "private_network", ip: ip_of(vm[:name])
      node.vm.network "public_network" if vm[:public]

      node.vm.provider "virtualbox" do |vb|
        vb.name = vm[:name]
        vb.cpus = 1
        vb.memory = vm[:memory]
      end

      provision_ssh_access(node, vm)
      provision_app(node, vm)
      provision_logging(node, vm)
    end
  end
end
