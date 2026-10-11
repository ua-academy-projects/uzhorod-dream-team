ENV['VAGRANT_DEFAULT_PROVIDER'] = 'virtualbox'

host_env = {}
if File.exist?(".env")
  File.readlines(".env").each do |line|
    key, value = line.strip.split("=", 2)
    host_env[key] = value if key && !key.start_with?("#") && value
  end
end
%w[POSTGRES_PASSWORD REDIS_PASSWORD RABBITMQ_PASSWORD].each do |key|
  abort "Set #{key} in .env (see .env.example)" if host_env[key].to_s.empty?
end

setting = ->(key, default) { host_env[key].to_s.empty? ? default : host_env[key] }

NET = "192.168.56"

VMS = {
  "weather-postgres-db" => { ip: "#{NET}.10", memory: 1536, script: "db.sh" },
  "weather-fetcher"     => { ip: "#{NET}.11", memory: 1024, script: "fetcher.sh" },
  "weather-history"     => { ip: "#{NET}.12", memory: 1024, script: "history.sh" },
  "weather-frontend"    => { ip: "#{NET}.13", memory: 1024, script: "frontend.sh", lan: true },
}

PROVISION_ENV = {
  "DB_IP"             => VMS["weather-postgres-db"][:ip],
  "HISTORY_IP"        => VMS["weather-history"][:ip],
  "POSTGRES_PASSWORD" => host_env["POSTGRES_PASSWORD"],
  "POSTGRES_DB"       => setting.("POSTGRES_DB", "weather"),
  "REDIS_PASSWORD"    => host_env["REDIS_PASSWORD"],
  "RABBITMQ_PASSWORD" => host_env["RABBITMQ_PASSWORD"],
  "TRIGGER_TOKEN"     => host_env.fetch("TRIGGER_TOKEN", ""),
  "CRON_SCHEDULE"     => setting.("CRON_SCHEDULE", "*/15 * * * *"),
  "HISTORY_PORT"      => setting.("HISTORY_PORT", "3001"),
  "FRONTEND_PORT"     => setting.("FRONTEND_PORT", "4173"),
  "POSTGRES_PORT"     => setting.("POSTGRES_PORT", "5432"),
  "REDIS_PORT"        => setting.("REDIS_PORT", "6379"),
  "RABBITMQ_PORT"     => setting.("RABBITMQ_PORT", "5672"),
  "RABBITMQ_UI_PORT"  => setting.("RABBITMQ_UI_PORT", "15672"),
}

Vagrant.configure("2") do |config|
  config.vm.box = "debian/bookworm64"
  config.vm.box_check_update = false
  config.vm.synced_folder ".", "/vagrant", type: "virtualbox"

  VMS.each do |name, vm|
    config.vm.define name do |node|
      node.vm.hostname = name
      node.vm.network "private_network", ip: vm[:ip]

      if vm[:lan]
        node.vm.network "public_network", bridge: host_env["BRIDGE_IF"]
      end

      node.vm.provider :virtualbox do |v|
        v.memory = vm[:memory]
        v.cpus   = vm.fetch(:cpus, 1)
      end

      node.vm.provision "shell", name: "provision-#{name}", path: "provision/#{vm[:script]}", env: PROVISION_ENV

      if vm[:lan]
        node.vm.provision "shell", name: "show-lan-ip", run: "always",
          env: { "VM_NAME" => name, "PORT" => PROVISION_ENV["FRONTEND_PORT"], "SKIP" => "^(10\\.0\\.2|#{Regexp.escape(NET)})\\." },
          inline: 'ip=$(hostname -I | tr " " "\n" | grep -Ev "$SKIP" | head -n1); ' \
                  'echo "$VM_NAME LAN URL: http://${ip:-<no LAN address>}:$PORT"'
      end
    end
  end
end
