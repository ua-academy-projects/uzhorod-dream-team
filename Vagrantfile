File.foreach(".env") do |line|
    key, value = line.strip.split("=", 2)
    ENV[key] = value if key && value
end

def env_vars(*names)
    names.to_h { |name| [name, ENV[name]] }
end

require "json"
require_relative "configs/firewall"

Vagrant.configure("2") do |config|
    config.vm.box = "bento/ubuntu-24.04"

    machines = [
        {
            name: "bastion",
            host: ENV["BASTION_HOST"],
            memory: "512",
            cpus: 1,
            env: env_vars("FRONTEND_HOST", "FRONTEND_PORT")
        },
        {
            name: "database",
            host: ENV["POSTGRES_HOST"],
            memory: "1024",
            cpus: 1,
            env: env_vars(
                "POSTGRES_PORT",
                "POSTGRES_USER",
                "POSTGRES_PASSWORD",
                "POSTGRES_DB",
                "POSTGRES_RESTORE",
                "REDIS_PORT" ,
                "REDIS_PASSWORD",
                "RABBITMQ_HOST",
                "RABBITMQ_PORT",
                "RABBITMQ_MANAGEMENT_PORT",
                "RABBITMQ_USER",
                "RABBITMQ_PASSWORD",
                "QUEUE_TYPE",
                "CACHE_TYPE",
                "HISTORY_HOST",
                "FETCHER_HOST",
                "FRONTEND_HOST"
            )
        },
        {
            name: "fetcher",
            host: ENV["FETCHER_HOST"],
            memory: "1024",
            cpus: 1,
            env: env_vars(
                "FETCHER_PORT",
                "POSTGRES_HOST",
                "POSTGRES_PORT",
                "POSTGRES_USER",
                "POSTGRES_PASSWORD",
                "POSTGRES_DB",
                "RABBITMQ_HOST",
                "RABBITMQ_PORT",
                "RABBITMQ_MANAGEMENT_PORT",
                "RABBITMQ_USER",
                "RABBITMQ_PASSWORD",
                "QUEUE_TYPE",
            )
        },
        {
            name: "history",
            host: ENV["HISTORY_HOST"],
            memory: "2048",
            cpus: 1,
            env: env_vars(
                "HISTORY_PORT",
                "POSTGRES_HOST",
                "POSTGRES_PORT",
                "POSTGRES_USER",
                "POSTGRES_PASSWORD",
                "POSTGRES_DB",
                "REDIS_HOST",
                "REDIS_PORT",
                "REDIS_PASSWORD",
                "RABBITMQ_HOST",
                "RABBITMQ_PORT",
                "RABBITMQ_USER",
                "RABBITMQ_PASSWORD",
                "QUEUE_TYPE",
                "CACHE_TYPE",
                "FETCHER_HOST",
                "FETCHER_PORT"
            )
        },
        {
            name: "frontend",
            host: ENV["FRONTEND_HOST"],
            memory: "512",
            cpus: 1,
            script: "scripts/frontend.sh",
            env: env_vars(
                "FRONTEND_PORT",
                "POSTGRES_HOST",
                "HISTORY_HOST",
                "HISTORY_PORT"
            )
        }
    ]

    machines.each do |machine|
        config.vm.define machine[:name] do |node|
            node.vm.hostname = machine[:name]

            node.vm.network "private_network", ip: machine[:host]
            if machine[:name] == "bastion"
                node.vm.network "public_network", bridge: "en0: Wi-Fi"
            end

            node.vm.provider :virtualbox do |vb|
                vb.name = "vagrant_#{machine[:name]}"
                vb.memory = machine[:memory]
                vb.cpus = machine[:cpus]
            end

            node.vm.provision "shell",
                path: "scripts/#{machine[:name]}.sh",
                env: machine[:env] || {}

            unless machine[:name] == "bastion"
                rules = FIREWALL_RULES.select do |rule|
                    rule[:to] == "*" || rule[:to] == machine[:name]
                end
                
                node.vm.provision "shell",
                    path: "scripts/firewall/ufw.sh",
                    args: [JSON.generate(rules)]
            end

            # add to known_hosts
            if machine[:name] == "database"
                node.vm.provision "collect_keys",
                    type: "shell",
                    run: "never",
                    path: "scripts/ssh/setup_vm_known_hosts.sh",
                    args: machines
                        .reject { |m| m[:name] == "database" }
                        .flat_map { |m| [m[:name].to_s, m[:host].to_s] }
            end
            
            node.trigger.after :up do |trigger|
                trigger.name = "Export SSH host key"
                trigger.run_remote = {
                    path: "scripts/ssh/setup_ssh.sh",
                    args: [machine[:name]]
                }
            end

            # mac stores .pub keys in known_hosts
            node.trigger.after :up do |trigger|
                trigger.name = "Configure host SSH"
                trigger.run = {
                    path: "scripts/ssh/setup_known_hosts.sh",
                    args: [machine[:name], machine[:host]]
                }
            end

            # database collect .pub keys
            node.trigger.after :up do |trigger|
                trigger.only_on = ["frontend"]
                trigger.name = "Collect SSH keys"

                trigger.run = {
                    inline: "vagrant provision database --provision-with collect_keys"
                }
            end
        end
    end
end