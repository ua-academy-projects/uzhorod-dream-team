ROOT = File.expand_path("..", __dir__)

ENV_VARS = File.readlines("#{ROOT}/.env", chomp: true)
  .reject { |l| l.strip.empty? || l.start_with?("#") }
  .to_h { |l| l.split("=", 2) }

def ip_of(name)
  ENV_VARS.fetch(VMS.find { |vm| vm[:name] == name }.fetch(:ip))
end
