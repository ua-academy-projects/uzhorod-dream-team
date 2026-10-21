require "uri"

# paths are resolved against the directory of this Vagrantfile, not the current directory:
# vagrant may be run from a subdirectory (e.g. deploy/), and the parse-time reads below must not depend on that
ROOT = File.dirname(File.expand_path(__FILE__))

# key pair of the log collector (db pulls logs from the other VMs over SSH); generated once, kept out of git
LOGKEY = File.join(ROOT, "deploy/logpull_key")
system("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "logpull", "-f", LOGKEY) unless File.exist?(LOGKEY)

# read-only log access for the collector: the public key and the logpull user + forced command
def logpull_target(vm)
  vm.provision "logpull-pub", type: "file", source: "#{LOGKEY}.pub", destination: "/tmp/logpull.pub"
  vm.provision "logpull-target", type: "shell", path: "provision/logpull-target.sh"
end

ENC = ->(v) { URI.encode_www_form_component(URI.decode_www_form_component(v.to_s)) }

# URLs from variable VAR (scheme is a regex for the URL scheme) in an env file
def env_urls(file, var, scheme)
  file = File.join(ROOT, file)
  return [] unless File.exist?(file)
  File.readlines(file).filter_map { |l| l[/^#{var}=(#{scheme}:\/\/\S+)/, 1] }.map { |url| URI(url) }
end

# PGMQ_URL (from deploy/queue.env) and DATABASE_URL (from deploy/env/history.env) -> "user:pass:db:pgmq,..."
# for provision/db.sh (fields urlencoded; pgmq=1 marks the queue DB, which also holds the hstore cache)
def pg_targets
  { "deploy/queue.env" => ["PGMQ_URL", 1], "deploy/env/history.env" => ["DATABASE_URL", 0] }.flat_map do |file, (var, pgmq)|
    env_urls(file, var, "postgres(?:ql)?").map do |u|
      [ENC.(u.user), ENC.(u.password), ENC.(u.path.delete_prefix("/")), pgmq].join(":")
    end
  end.join(",")
end

# RABBITMQ_URL and REDIS_URL from deploy/queue.env -> variables for provision/mq.sh
def mq_env
  amqp = env_urls("deploy/queue.env", "RABBITMQ_URL", "amqps?").first
  redis = env_urls("deploy/queue.env", "REDIS_URL", "rediss?").first
  vhost = amqp && !amqp.path.delete_prefix("/").empty? ? amqp.path.delete_prefix("/") : "%2f"
  {
    "RABBIT_USER" => amqp && ENC.(amqp.user), "RABBIT_PASS" => amqp && ENC.(amqp.password), "RABBIT_VHOST" => ENC.(vhost),
    "REDIS_PASSWORD" => redis && ENC.(redis.password),
  }.compact
end

Vagrant.configure("2") do |config|
  config.vm.box = "debian/trixie64"
  config.vm.synced_folder ".", "/vagrant", disabled: true

  config.vm.provider :libvirt do |lv|
    lv.memory = 512
    lv.cpus = 1
  end

  # your public key on every machine (for ProxyJump from the laptop)
  config.vm.provision "file", source: "~/.ssh/id_ed25519.pub", destination: "/tmp/me.pub"
  config.vm.provision "shell", inline: "cat /tmp/me.pub >> /home/vagrant/.ssh/authorized_keys"

  config.vm.define "bastion" do |b|
    b.vm.hostname = "bastion"
    # "public subnet"
    b.vm.network :private_network, ip: "192.168.50.10",
      libvirt__network_name: "dmz",
      libvirt__forward_mode: "nat",
      libvirt__dhcp_enabled: false
    # "private subnet"
    b.vm.network :private_network, ip: "10.10.0.10",
      libvirt__network_name: "private",
      libvirt__forward_mode: "veryisolated",
      libvirt__dhcp_enabled: false
    b.vm.provision "shell", path: "provision/bastion.sh"
    logpull_target(b.vm)
    # optional public access through a Cloudflare Tunnel (needs deploy/cloudflared.env with TUNNEL_TOKEN)
    if File.exist?(File.join(ROOT, "deploy/cloudflared.env"))
      b.vm.provision "cloudflared-env", type: "file", source: "deploy/cloudflared.env", destination: "/tmp/cloudflared.env"
    end
    b.vm.provision "cloudflared", type: "shell", path: "provision/cloudflared.sh"
  end

  { "frontend" => "10.10.0.20", "fetcher" => "10.10.0.21", "history" => "10.10.0.22", "db" => "10.10.0.25", "mq" => "10.10.0.30" }.each do |name, ip|
    config.vm.define name do |m|
      m.vm.hostname = name
      m.vm.network :private_network, ip: ip,
        libvirt__network_name: "private",
        libvirt__forward_mode: "veryisolated",
        libvirt__dhcp_enabled: false
      m.vm.provider(:libvirt) { |lv| lv.memory = 1024 } if name == "mq" # Erlang + Redis

      # db, mq, frontend: install packages while the internet is still reachable via mgmt, i.e. before private.sh
      if name == "db"
        m.vm.provision "db", type: "shell", path: "provision/db.sh", env: { "PG_TARGETS" => pg_targets }
        m.vm.provision "logpull-key", type: "file", source: LOGKEY, destination: "/tmp/logpull_key"
        m.vm.provision "logpull-collector", type: "shell", path: "provision/logpull-collector.sh"
      elsif name == "mq"
        m.vm.provision "mq", type: "shell", path: "provision/mq.sh", env: mq_env
      elsif name == "frontend"
        m.vm.provision "frontend", type: "shell", path: "provision/frontend.sh"
      end
      m.vm.provision "shell", path: "provision/private.sh", env: { "ROLE" => name }

      # systemd unit and service env; the binary and queue.env are rolled out by deploy/build.sh and deploy/set-queue.sh
      if %w[fetcher history].include?(name)
        m.vm.provision "svc-unit", type: "file", source: "deploy/systemd/#{name}.service", destination: "/tmp/#{name}.service"
        m.vm.provision "svc-env", type: "file", source: "deploy/env/#{name}.env", destination: "/tmp/#{name}.env"
        m.vm.provision "svc-install", type: "shell", inline: <<~SH
          install -m644 /tmp/#{name}.service /etc/systemd/system/#{name}.service
          install -m600 /tmp/#{name}.env /etc/#{name}.env
          systemctl daemon-reload && systemctl enable #{name}
        SH
        logpull_target(m.vm)
      end
    end
  end
end