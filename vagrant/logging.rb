LOG_COLLECTOR_KEY = "#{ROOT}/.vagrant/log_collector_ed25519"

wsl_ssh("collector-key") unless File.exist?(LOG_COLLECTOR_KEY)

def remote_output(machine, command, sudo: false)
  output = +""
  machine.communicate.public_send(sudo ? :sudo : :execute, command, error_check: false) do |type, data|
    output << data if type == :stdout
  end
  output
end

def sync_collector_known_hosts(env)
  collector = env.machine(LOG_COLLECTOR.to_sym, :virtualbox)
  return unless collector.state.id == :running

  known_hosts = "/home/logcollector/.ssh/known_hosts"
  entries = remote_output(collector, "cat #{known_hosts} 2>/dev/null", sudo: true)
    .lines.map(&:strip).reject(&:empty?).to_h { |line| [line.split.first, line] }

  VMS.each do |vm|
    machine = env.machine(vm[:name].to_sym, :virtualbox)
    next unless machine.state.id == :running

    key = remote_output(machine, "cat /etc/ssh/ssh_host_ed25519_key.pub").split.first(2)
    entries[ip_of(vm[:name])] = "#{ip_of(vm[:name])} #{key.join(' ')}" if key.size == 2
  rescue StandardError => e
    warn "#{vm[:name]}: host key not refreshed for the log collector (#{e.message.lines.first&.strip})"
  end

  collector.communicate.sudo(
    "test -d /home/logcollector/.ssh || exit 0; " \
    "printf '%s\\n' #{entries.values.map { |e| "'#{e}'" }.join(' ')} > #{known_hosts} && " \
    "chown logcollector:logcollector #{known_hosts} && chmod 644 #{known_hosts}"
  )
rescue StandardError => e
  warn "log collector host keys not synced (#{e.message.lines.first&.strip})"
end

def provision_logging(node, vm)
  node.vm.provision "log-source", type: "shell", path: "scripts/provision/log_source.sh", env: {
    "LOG_COLLECTOR_IP" => ip_of(LOG_COLLECTOR),
    "LOG_COLLECTOR_PUBKEY" => File.read("#{LOG_COLLECTOR_KEY}.pub").strip
  }

  if vm[:name] == LOG_COLLECTOR
    node.vm.provision "log-collector-key", type: "file",
      source: LOG_COLLECTOR_KEY, destination: "/home/vagrant/log_collector_ed25519"
    node.vm.provision "log-collector", type: "shell", path: "scripts/provision/log_collector.sh", env: {
      "LOG_SOURCES" => VMS.map { |v| "#{v[:name]}=#{ip_of(v[:name])}" }.join(" "),
      "LOG_COLLECT_CRON" => ENV_VARS.fetch("LOG_COLLECT_CRON"),
      "LOG_RETENTION_DAYS" => ENV_VARS.fetch("LOG_RETENTION_DAYS")
    }
  end

  node.trigger.after [:up, :reload, :provision] do |t|
    t.info = "Syncing #{LOG_COLLECTOR} log collector host keys"
    t.ruby { |env, _machine| sync_collector_known_hosts(env) }
  end
end
