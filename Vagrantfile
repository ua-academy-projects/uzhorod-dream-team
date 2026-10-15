require "fileutils"

ENV['VAGRANT_DEFAULT_PROVIDER'] = 'virtualbox'

host_env = {}
if File.exist?(".env")
  File.readlines(".env").each do |line|
    key, value = line.strip.split("=", 2)
    host_env[key] = value if key && !key.start_with?("#") && value
  end
end
setting = ->(key, default) { host_env[key].to_s.empty? ? default : host_env[key] }

USE_REDIS_RABBITMQ = case setting.("USE_REDIS_RABBITMQ", "true").strip.downcase
                     when "true", "1", "yes" then "true"
                     when "false", "0", "no" then "false"
                     else abort "USE_REDIS_RABBITMQ in .env must be true or false, got \"#{host_env["USE_REDIS_RABBITMQ"]}\""
                     end

%w[POSTGRES_PASSWORD FETCHER_DB_PASSWORD REDIS_PASSWORD RABBITMQ_PASSWORD].each do |key|
  abort "Set #{key} in .env (see .env.example)" if host_env[key].to_s.empty?
end

abort "Put the SSH public key into id_ed25519.pub" unless File.exist?("id_ed25519.pub")

LOGPULL_KEY = ".vagrant/logpull_ed25519"
unless File.exist?(LOGPULL_KEY)
  FileUtils.mkdir_p(File.dirname(LOGPULL_KEY))
  system("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "weather-logpull", "-f", LOGPULL_KEY) \
    or abort "ssh-keygen failed to create #{LOGPULL_KEY}"
end

NET = "192.168.56"

VMS = {
  "weather-postgres-db" => {
    ip: "#{NET}.10", memory: 1536, script: "db.sh", sync: %w[postgres],
    env: %w[USE_REDIS_RABBITMQ DB_IP HISTORY_IP FETCHER_IP POSTGRES_PASSWORD POSTGRES_DB POSTGRES_PORT FETCHER_DB_PASSWORD
            REDIS_PASSWORD REDIS_PORT RABBITMQ_PASSWORD RABBITMQ_PORT RABBITMQ_UI_PORT],
  },
  "weather-fetcher" => {
    ip: "#{NET}.11", memory: 1024, script: "fetcher.sh", sync: %w[fetcher],
    env: %w[USE_REDIS_RABBITMQ DB_IP RABBITMQ_PASSWORD RABBITMQ_PORT POSTGRES_DB POSTGRES_PORT FETCHER_DB_PASSWORD],
  },
  "weather-history" => {
    ip: "#{NET}.12", memory: 1024, script: "history.sh", sync: %w[history scheduler],
    env: %w[USE_REDIS_RABBITMQ DB_IP HISTORY_IP HISTORY_PORT POSTGRES_PASSWORD POSTGRES_DB POSTGRES_PORT REDIS_PASSWORD REDIS_PORT
            RABBITMQ_PASSWORD RABBITMQ_PORT TRIGGER_TOKEN CRON_SCHEDULE LOGPULL_KEY_B64 LOG_SOURCES],
  },
  "weather-frontend" => {
    ip: "#{NET}.13", memory: 1024, script: "frontend.sh", sync: %w[frontend], lan: true,
    env: %w[HISTORY_IP HISTORY_PORT FRONTEND_PORT],
  },
}

PROVISION_ENV = {
  "USE_REDIS_RABBITMQ"  => USE_REDIS_RABBITMQ,
  "DB_IP"               => VMS["weather-postgres-db"][:ip],
  "FETCHER_IP"          => VMS["weather-fetcher"][:ip],
  "HISTORY_IP"          => VMS["weather-history"][:ip],
  "SSH_PUBKEY"          => File.read("id_ed25519.pub").strip,
  "LOGPULL_PUBKEY"      => File.read("#{LOGPULL_KEY}.pub").strip,
  "LOGPULL_KEY_B64"     => [File.read(LOGPULL_KEY)].pack("m0"),
  "LOG_SOURCES"         => VMS.reject { |name, _| name == "weather-history" }.map { |name, vm| "#{name}=#{vm[:ip]}" }.join(" "),
  "LOG_RETENTION_DAYS"  => setting.("LOG_RETENTION_DAYS", "7"),
  "POSTGRES_PASSWORD"   => host_env["POSTGRES_PASSWORD"],
  "POSTGRES_DB"         => setting.("POSTGRES_DB", "weather"),
  "FETCHER_DB_PASSWORD" => host_env["FETCHER_DB_PASSWORD"].to_s,
  "REDIS_PASSWORD"      => host_env["REDIS_PASSWORD"].to_s,
  "RABBITMQ_PASSWORD"   => host_env["RABBITMQ_PASSWORD"].to_s,
  "TRIGGER_TOKEN"       => host_env.fetch("TRIGGER_TOKEN", ""),
  "CRON_SCHEDULE"       => setting.("CRON_SCHEDULE", "0 * * * *"),
  "HISTORY_PORT"        => setting.("HISTORY_PORT", "3001"),
  "FRONTEND_PORT"       => setting.("FRONTEND_PORT", "4173"),
  "POSTGRES_PORT"       => setting.("POSTGRES_PORT", "5432"),
  "REDIS_PORT"          => setting.("REDIS_PORT", "6379"),
  "RABBITMQ_PORT"       => setting.("RABBITMQ_PORT", "5672"),
  "RABBITMQ_UI_PORT"    => setting.("RABBITMQ_UI_PORT", "15672"),
}

Vagrant.configure("2") do |config|
  config.vm.box = "debian/bookworm64"
  config.vm.box_check_update = false
  config.vm.synced_folder ".", "/vagrant", disabled: true

  VMS.each do |name, vm|
    config.vm.define name do |node|
      node.vm.hostname = name

      vm[:sync].each do |dir|
        node.vm.synced_folder dir, "/vagrant/#{dir}", type: "virtualbox", mount_options: ["ro"]
      end

      node.vm.network "private_network", ip: vm[:ip]

      if vm[:lan]
        node.vm.network "public_network", bridge: host_env["BRIDGE_IF"]
      end

      node.vm.provider :virtualbox do |v|
        v.memory = vm[:memory]
        v.cpus   = vm.fetch(:cpus, 1)
      end

      node.vm.provision "file", source: "provision/common.sh", destination: "/tmp/weather-common.sh"
      node.vm.provision "shell", name: "provision-#{name}", path: "provision/#{vm[:script]}",
        env: PROVISION_ENV.slice("SSH_PUBKEY", "LOGPULL_PUBKEY", "HISTORY_IP", "LOG_RETENTION_DAYS", *vm[:env])

      if vm[:lan]
        node.vm.provision "shell", name: "show-lan-ip", run: "always",
          env: { "VM_NAME" => name, "PORT" => PROVISION_ENV["FRONTEND_PORT"], "SKIP" => "^(10\\.0\\.2|#{Regexp.escape(NET)})\\." },
          inline: 'ip=$(hostname -I | tr " " "\n" | grep -Ev "$SKIP" | head -n1); ' \
                  'echo "$VM_NAME LAN URL: http://${ip:-<no LAN address>}:$PORT"'
      end
    end
  end
end
