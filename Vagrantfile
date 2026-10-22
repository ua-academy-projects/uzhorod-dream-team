require "yaml"

# Run all Vagrant commands from WSL in this folder. VirtualBox runs on Windows.
# Code files are taken from this folder: paths are built from __dir__
# (the Vagrantfile folder), so they work from any subfolder too.
APP_CONFIG = YAML.safe_load(
  File.read(File.join(__dir__, "weather-vm.yml")),
  permitted_classes: [],
  aliases: false
)

%w[postgres_role postgres_database].each do |key|
  value = APP_CONFIG.fetch(key)
  unless value.is_a?(String) && value.match?(/\A[a-z_][a-z0-9_]{0,62}\z/)
    raise "#{key} in weather-vm.yml must be a lowercase PostgreSQL identifier"
  end
end

# Mode of the app (see weather-vm.yml). Passed to the VMs and the apps as APP_MODE.
APP_MODE = APP_CONFIG.fetch("app_mode")
unless %w[rabbitmq postgres].include?(APP_MODE)
  raise "app_mode in weather-vm.yml must be rabbitmq or postgres, not #{APP_MODE.inspect}"
end
QUEUE_POLL_INTERVAL_SECONDS = APP_CONFIG.fetch("queue_poll_interval_seconds")
unless QUEUE_POLL_INTERVAL_SECONDS.is_a?(Integer) && QUEUE_POLL_INTERVAL_SECONDS.positive?
  raise "queue_poll_interval_seconds in weather-vm.yml must be a positive whole number, " \
        "not #{QUEUE_POLL_INTERVAL_SECONDS.inspect}"
end

# The database password is a secret: it is read only from .env (not in Git).
# Lines look like KEY=value; empty lines and lines starting with # are skipped.
ENV_FILE = File.join(__dir__, ".env")
unless File.file?(ENV_FILE)
  raise "#{ENV_FILE} not found. Copy .env.example to .env and set WEATHER_DB_PASSWORD"
end
SECRETS = File.readlines(ENV_FILE, chomp: true).each_with_object({}) do |line, values|
  next if line.strip.empty? || line.strip.start_with?("#")
  key, value = line.split("=", 2)
  values[key.strip] = value.to_s.strip
end
DB_PASSWORD = SECRETS.fetch("WEATHER_DB_PASSWORD", "")
unless DB_PASSWORD.match?(/\A[A-Za-z0-9]{16,}\z/) && DB_PASSWORD != "change-me"
  raise "WEATHER_DB_PASSWORD in .env must be at least 16 letters or digits"
end

RABBITMQ_PASSWORD = SECRETS.fetch("RABBITMQ_PASSWORD", "")
unless RABBITMQ_PASSWORD.match?(/\A[A-Za-z0-9]{16,}\z/)
  raise "RABBITMQ_PASSWORD in .env must be at least 16 letters or digits"
end


FETCHER_DB_PASSWORD = SECRETS.fetch("FETCHER_DB_PASSWORD", "")

unless FETCHER_DB_PASSWORD.match?(/\A[A-Za-z0-9]{16,}\z/) && FETCHER_DB_PASSWORD != DB_PASSWORD
  raise "FETCHER_DB_PASSWORD in .env must be at least 16 letters or digits, not WEATHER_DB_PASSWORD"
end

REDIS_PASSWORD = SECRETS.fetch("REDIS_PASSWORD", "")
unless REDIS_PASSWORD.match?(/\A[A-Za-z0-9]{16,}\z/)
  raise "REDIS_PASSWORD in .env must be at least 16 letters or digits"
end

# Optional: Wi-Fi IPv4 of this laptop. If set, UI is also opened on it for the home LAN.
# It is in .env, not in Git, because DHCP gives each network its own address.
UI_LAN_IP = SECRETS.fetch("UI_LAN_IP", "")
unless UI_LAN_IP.empty? || UI_LAN_IP.match?(/\A\d{1,3}(\.\d{1,3}){3}\z/)
  raise "UI_LAN_IP in .env must be an IPv4 address or empty"
end

# Public SSH key of the project owner (for "ssh weather/fetcher/history" from WSL).
# Only the .pub file is read; the private key stays in ~/.ssh of WSL.
SSH_PUBLIC_KEY_FILE = File.expand_path("~/.ssh/weather_history_ed25519.pub")
SSH_PUBLIC_KEY = File.file?(SSH_PUBLIC_KEY_FILE) ? File.read(SSH_PUBLIC_KEY_FILE).strip : ""

# External network (VirtualBox host-only, reachable only from this computer: Windows and WSL).
# "ssh bastion" from WSL comes to this address of bastion-vm.
BASTION_PUBLIC_IP = "192.168.56.13"
# Only bastion-vm is in the host-only network. weather, fetcher and history are not:
# from Windows and WSL they are reachable only through bastion (and Vagrant's own NAT ports).
HOST_ONLY_IPS = { "bastion-vm" => BASTION_PUBLIC_IP }.freeze

# Internal network (VirtualBox Internal Network): only the VMs are in it, Windows and WSL
# have no adapter there, so they cannot reach these addresses. The services talk here.
INTERNAL_NETWORK = "weather-internal"
DB_IP = "10.10.10.10"
FETCHER_IP = "10.10.10.11"
HISTORY_IP = "10.10.10.12"
# Internal address of bastion-vm: SSH to the internal VMs comes only from it (provision/ssh-access.sh).
BASTION_IP = "10.10.10.13"

DB_ENV = {
  "WEATHER_DB_ROLE" => APP_CONFIG.fetch("postgres_role"),
  "WEATHER_DB_NAME" => APP_CONFIG.fetch("postgres_database"),
  "WEATHER_DB_PASSWORD" => DB_PASSWORD
}.freeze

# RabbitMQ runs in weather-vm, next to PostgreSQL (no separate VM).
# vhost is a separate "space" inside RabbitMQ with its own queues and permissions.
RABBITMQ_ENV = {
  "RABBITMQ_USER" => "weather",
  "RABBITMQ_VHOST" => "weather",
  "RABBITMQ_PASSWORD" => RABBITMQ_PASSWORD
}.freeze

# Redis also runs in weather-vm. Only History uses it.
REDIS_ENV = { "REDIS_PASSWORD" => REDIS_PASSWORD }.freeze

# Three VMs. weather-vm is the original VM (it keeps the database and snapshots),
# so its name stays the same; now it runs PostgreSQL, RabbitMQ and Redis.
# scripts run in the listed order, all with the same env.
VMS = [
    {
    name: "bastion-vm",
    ip: BASTION_IP,
    cpus: 1,
    memory: 512,
    files: [],
    # Only SSH comes in (bastion-firewall.sh).
    scripts: %w[provision/bastion-firewall.sh],
    env: {},
    ports: []
  },
  {
    name: "weather-vm",
    ip: DB_IP,
    cpus: 1,
    memory: 1536, # MB; RabbitMQ (Erlang) needs about 150-200 MB more
    files: %w[db/schema.sql],
    # RabbitMQ and Redis run in Docker containers (broker.sh, cache.sh); PostgreSQL does not.
    # db-extensions: pgmq, pg_cron and hstore (for app_mode postgres).
    # db-mode: access of Fetcher to PostgreSQL by app_mode, without a restart of PostgreSQL.
    scripts: %w[
      provision/db.sh provision/db-extensions.sh provision/db-mode.sh provision/docker.sh provision/broker.sh provision/cache.sh
      provision/db-firewall.sh provision/ssh-access.sh
    ],
    env: DB_ENV.merge(RABBITMQ_ENV).merge(REDIS_ENV)
               .merge("DB_IP" => DB_IP, "FETCHER_IP" => FETCHER_IP, "HISTORY_IP" => HISTORY_IP,
                      "BASTION_IP" => BASTION_IP, "APP_MODE" => APP_MODE,
                      "FETCHER_DB_PASSWORD" => FETCHER_DB_PASSWORD),
    ports: []
  },
  {
    name: "fetcher-vm",
    ip: FETCHER_IP,
    cpus: 1,
    memory: 512,
    # Fetcher runs in a Docker container: these files are the build context of the image.
    files: %w[
      fetcher/main.py fetcher/config.py fetcher/messages.py fetcher/pgqueue.py fetcher/weather.py
      fetcher/requirements.txt fetcher/Dockerfile fetcher/.dockerignore
    ],
    # fetcher-image builds the image, fetcher (re)creates the container with the settings
    # of app_mode; a switch of the mode runs only "fetcher" (no new build).
    scripts: %w[provision/docker.sh provision/fetcher-image.sh provision/fetcher.sh provision/ssh-access.sh],
    # Only the secrets of Fetcher: its own database password, not the one of History.
    env: RABBITMQ_ENV.merge("DB_IP" => DB_IP, "BASTION_IP" => BASTION_IP, "APP_MODE" => APP_MODE,
                            "QUEUE_POLL_INTERVAL_SECONDS" => QUEUE_POLL_INTERVAL_SECONDS.to_s,
                            "WEATHER_DB_NAME" => APP_CONFIG.fetch("postgres_database"),
                            "FETCHER_DB_PASSWORD" => FETCHER_DB_PASSWORD),
    ports: []
  },
  {
    name: "history-vm",
    ip: HISTORY_IP,
    cpus: 1,
    # go build of go-redis in the build stage of the image needs ~450 MB next to Docker;
    # with 768 MB it swapped for more than 20 minutes.
    memory: 1024,
    # History runs in a Docker container: these files are the build context of the image.
    files: %w[
      history/main.go history/messages.go history/pgqueue.go history/queue.go history/settings.go
      history/storage.go
      history/go.mod history/go.sum history/Dockerfile
      ui/index.html ui/app.js ui/style.css
      .dockerignore
    ],
    # history-image builds the image, history (re)creates the container with the settings
    # of app_mode; a switch of the mode runs only "history" (no new build).
    scripts: %w[provision/docker.sh provision/history-image.sh provision/history.sh provision/ssh-access.sh],
    env: DB_ENV.merge(RABBITMQ_ENV).merge(REDIS_ENV)
               .merge("DB_IP" => DB_IP, "BASTION_IP" => BASTION_IP, "APP_MODE" => APP_MODE,
                      "QUEUE_POLL_INTERVAL_SECONDS" => QUEUE_POLL_INTERVAL_SECONDS.to_s),
    # Port in the VM (guest) -> port on Windows (host). 127.0.0.1 — this computer only;
    # UI_LAN_IP — also the home LAN (Windows Firewall rule limits it to the home subnet).
    # Only UI/API: PostgreSQL and RabbitMQ are not forwarded.
    ports: [{ guest: 8080, host: 8081, host_ip: "127.0.0.1" }] +
           (UI_LAN_IP.empty? ? [] : [{ guest: 8080, host: 8081, host_ip: UI_LAN_IP }])
  }
].freeze

Vagrant.configure("2") do |config|
  config.vm.box = "bento/ubuntu-24.04"

  # Windows VirtualBox cannot share a folder from the WSL file system,
  # and the VMs do not need /vagrant: code is copied by the "file" steps below.
  config.vm.synced_folder ".", "/vagrant", disabled: true

  # WSL cannot reach Windows 127.0.0.1, where the VMs' SSH ports are forwarded.
  # SSH goes through ssh-proxy.ps1, which runs on Windows.
  if Vagrant::Util::Platform.wsl?
    proxy_script = IO.popen(["wslpath", "-m", File.join(__dir__, "ssh-proxy.ps1")], &:read).strip
    config.ssh.proxy_command =
      "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass " \
      "-File '#{proxy_script}' %h %p"
  end

  VMS.each do |vm|
    config.vm.define vm[:name] do |node|
      node.vm.hostname = vm[:name]
      # Host-only (external) only for bastion-vm; internal network for every VM.
      if HOST_ONLY_IPS.key?(vm[:name])
        node.vm.network "private_network", ip: HOST_ONLY_IPS.fetch(vm[:name])
      end
      node.vm.network "private_network", ip: vm[:ip], virtualbox__intnet: INTERNAL_NETWORK

      vm[:ports].each do |port|
        node.vm.network "forwarded_port",
                        guest: port[:guest], host: port[:host], host_ip: port[:host_ip]
      end

      node.vm.provider "virtualbox" do |vb|
        vb.name = vm[:name]
        vb.cpus = vm[:cpus]
        vb.memory = vm[:memory]
        # provision/timesync.sh turns off vboxadd-service (it conflicts with NTP).
        # Without it Vagrant would wrongly warn "no guest additions" on every start.
        vb.check_guest_additions = false
      end

      # Correct time in every VM (NTP via systemd-timesyncd).
      node.vm.provision "timesync", type: "shell", path: File.join(__dir__, "provision/timesync.sh")

      # The public SSH key of the project owner, next to the key of Vagrant.
      # Only this step: vagrant provision --provision-with ssh-key
      if SSH_PUBLIC_KEY.empty?
        node.vm.provision "ssh-key", type: "shell",
                          inline: "echo 'WARNING: #{SSH_PUBLIC_KEY_FILE} not found, " \
                                  "ssh #{vm[:name].delete_suffix('-vm')} will not work (see README)' >&2"
      else
        # On the internal VMs the key works only from bastion-vm (from= in authorized_keys),
        # so it cannot be used through the NAT ports of Vagrant. On bastion-vm: from anywhere.
        node.vm.provision "ssh-key", type: "shell", path: File.join(__dir__, "provision/ssh-key.sh"),
                          env: { "SSH_PUBLIC_KEY" => SSH_PUBLIC_KEY,
                                 "SSH_KEY_FROM" => vm[:name] == "bastion-vm" ? "" : BASTION_IP }
      end

      # SSH login only with a key, no password (Vagrant also logs in with its key).
      # Only this step: vagrant provision --provision-with ssh-no-password
      node.vm.provision "ssh-no-password", type: "shell",
                        path: File.join(__dir__, "provision/ssh-no-password.sh")

      # Folders for the copied code (the "file" step does not create them).
      # The old copy is removed first: the "file" step only adds files, so a file
      # deleted from the project (e.g. history/fetcher.go) would stay in the VM.
      folders = vm[:files].map { |path| "/home/vagrant/weather-history/#{File.dirname(path)}" }.uniq
            unless vm[:files].empty?
        node.vm.provision "shell",
                          inline: "rm -rf /home/vagrant/weather-history && " \
                                  "install -d -o vagrant -g vagrant #{folders.join(' ')}"
      end

      vm[:files].each do |relative_path|
        node.vm.provision "file",
                          source: File.join(__dir__, relative_path),
                          destination: "/home/vagrant/weather-history/#{relative_path}"
      end

      # Each script step is named after its file (db, broker, docker, cache, ...), so one
      # step can be run alone without the others, e.g. without restarting PostgreSQL:
      #   vagrant provision weather-vm --provision-with docker,cache,db-firewall
      vm[:scripts].each do |script|
        node.vm.provision File.basename(script, ".sh"), type: "shell",
                          path: File.join(__dir__, script), env: vm[:env]
      end
    end
  end
end
