require "fileutils"

BACKENDS = {
  "QUEUE_BACKEND" => %w[rabbitmq postgres pgmq],
  "SESSION_BACKEND" => %w[redis postgres hstore]
}.freeze

BACKENDS.each do |key, allowed|
  value = ENV_VARS.fetch(key)
  abort "#{key} must be one of: #{allowed.join(', ')} (got '#{value}')" unless allowed.include?(value)
end

def compose_profiles
  profiles = []
  profiles << "rabbitmq" if ENV_VARS["QUEUE_BACKEND"] == "rabbitmq"
  profiles << "redis" if ENV_VARS["SESSION_BACKEND"] == "redis"
  profiles.join(",")
end

def app_compose(vm)
  "#{ROOT}/deploy/#{vm[:name].delete_prefix("iss-")}/compose.yaml"
end

def stage_app_config(vm)
  compose = app_compose(vm)
  dir = "#{ROOT}/.vagrant/iss-config/#{vm[:name]}"
  FileUtils.mkdir_p(dir)
  FileUtils.cp(compose, dir)
  content = File.read(compose)
  env = content.scan(/\$\{(\w+)/).flatten.uniq.map { |k| "#{k}=#{ENV_VARS.fetch(k)}\n" }
  env << "COMPOSE_PROFILES=#{compose_profiles}\n" if content.include?("profiles:")
  File.write("#{dir}/iss.env", env.join)
  dir
end

def provision_app(node, vm)
  return unless File.exist?(app_compose(vm))

  node.vm.synced_folder vm[:src], "/opt/iss/src", mount_options: ["ro"] if vm[:src]

  node.vm.provision "docker", type: "shell", path: "scripts/provision/install_docker.sh"
  node.vm.provision "upload", type: "file",  source: stage_app_config(vm), destination: "/home/vagrant/iss-config"
  node.vm.provision "deploy", type: "shell", path: "scripts/provision/deploy.sh"
  node.vm.provision "postgres-roles", type: "shell", path: "scripts/provision/postgres_roles.sh" if vm[:name] == DATABASE
end
