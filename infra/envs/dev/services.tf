# The services (containers) and how each one runs: the same settings as the `docker run` flags in the
# Vagrantfile, written as docker compose. Which VM runs which service is set in config.json ("vms");
# for every VM a compose file is built from this catalog and handed to the VM in its metadata.
#
# Secrets are never here: "${DB_PASSWORD}" is filled in on the VM from Secret Manager (startup.sh).

locals {
  # where each service runs: service name => private IP of its VM (from config.json)
  at = merge([for vm, cfg in local.vms : { for s in cfg.services : s => local.ip[vm] }]...)

  # Secret Manager
  secret_ids = {
    DB_PASSWORD       = "${local.project.prefix}-db-password"
    REDIS_PASSWORD    = "${local.project.prefix}-redis-password"
    RABBITMQ_PASSWORD = "${local.project.prefix}-rabbitmq-password"
    TUNNEL_TOKEN      = "${local.project.prefix}-cloudflare-tunnel-token"
  }
  ssh_key_secret = "${local.project.prefix}-internal-ssh-key"

  # connection settings
  db_env = {
    DB_HOST     = local.at.postgres
    DB_PORT     = "5432"
    DB_NAME     = local.app.db_name
    DB_USER     = local.app.db_user
    DB_PASSWORD = "$${DB_PASSWORD}"
  }
  rabbitmq_env = {
    RABBITMQ_HOST     = local.at.rabbitmq
    RABBITMQ_PORT     = "5672"
    RABBITMQ_USER     = local.app.rabbitmq_user
    RABBITMQ_PASSWORD = "$${RABBITMQ_PASSWORD}"
    RABBITMQ_VHOST    = local.app.rabbitmq_vhost
  }
  redis_env = {
    REDIS_HOST     = local.at.redis
    REDIS_PORT     = "6379"
    REDIS_PASSWORD = "$${REDIS_PASSWORD}"
  }
  # a service gets ONLY the settings of the backend that is switched on (least privilege)
  # (written as filters, because `cond ? {...} : {...}` needs both sides to have the same keys)
  queue_env = merge(
    { for k, v in local.db_env : k => v if local.app.queue_backend == "postgres" },
    { for k, v in local.rabbitmq_env : k => v if local.app.queue_backend == "rabbitmq" },
  )
  cache_env = { for k, v in local.redis_env : k => v if local.app.cache_backend == "redis" }

  hardened  = { cap_drop = ["ALL"] }
  read_only = { cap_drop = ["ALL"], read_only = true, tmpfs = ["/tmp"] }

  # the catalog
  services = {
    postgres = {
      ports   = ["5432:5432"]
      volumes = ["pgdata:/var/lib/postgresql/data"]
      environment = {
        POSTGRES_DB       = local.app.db_name
        POSTGRES_USER     = local.app.db_user
        POSTGRES_PASSWORD = "$${DB_PASSWORD}"
        ALLOWED_CIDR      = local.network.subnet_cidr
      }
    }

    redis = {
      ports       = ["6379:6379"]
      volumes     = ["redisdata:/data"]
      environment = { REDIS_PASSWORD = "$${REDIS_PASSWORD}" }
    }

    rabbitmq = {
      hostname = "rabbitmq-citybikes" # RabbitMQ ties its data to the node name
      ports    = ["5672:5672", "15672:15672"]
      volumes  = ["rabbitmqdata:/var/lib/rabbitmq"]
      environment = {
        RABBITMQ_DEFAULT_USER  = local.app.rabbitmq_user
        RABBITMQ_DEFAULT_PASS  = "$${RABBITMQ_PASSWORD}"
        RABBITMQ_DEFAULT_VHOST = local.app.rabbitmq_vhost
      }
    }

    fetcher = merge(local.read_only, {
      environment = merge({
        QUEUE_BACKEND        = local.app.queue_backend
        CITYBIKES_NETWORK_ID = local.app.citybikes_network
      }, local.queue_env)
    })

    history = merge(local.read_only, {
      ports = ["8002:8002"]
      environment = merge({
        QUEUE_BACKEND = local.app.queue_backend
        CACHE_BACKEND = local.app.cache_backend
        POLL_INTERVAL = tostring(local.app.poll_interval)
      }, local.db_env, local.queue_env, local.cache_env)
    })

    ui = merge(local.hardened, {
      ports       = ["80:8080"]
      environment = { HISTORY_URL = "http://${local.at.history}:8002" }
    })

    cloudflared = merge(local.read_only, {
      environment = {
        TUNNEL_TOKEN              = "$${TUNNEL_TOKEN}"
        TUNNEL_TRANSPORT_PROTOCOL = local.app.cloudflare_tunnel_protocol
      }
    })
  }

  # compose file per VM
  compose_defaults = {
    restart      = "unless-stopped"
    security_opt = ["no-new-privileges:true"]
  }

  logging = {
    for vm, cfg in local.vms : vm => cfg.cloud_logging
    ? { driver = "gcplogs", options = tomap({ "gcp-log-cmd" = "false" }) }
    : { driver = "json-file", options = tomap({ "max-size" = "10m", "max-file" = "3" }) }
  }

  # name, image and build folder follow from the service name (./services/<name> in the repo)
  container = {
    for name in keys(local.services) : name => {
      container_name = name
      image          = "citybikes/${name}"
      build          = "./services/${name}"
    }
  }

  compose = {
    for vm, cfg in local.vms : vm => {
      name = "citybikes"
      services = {
        for s in cfg.services : s => merge(local.compose_defaults, { logging = local.logging[vm] }, local.container[s], local.services[s])
      }
    }
  }

  # named volumes ("pgdata:/...") of each VM must be declared at the top of its compose file
  compose_yaml = {
    for vm, c in local.compose : vm => yamlencode(merge(c, {
      volumes = {
        for v in distinct(flatten([
          for s in values(c.services) : [for m in try(s.volumes, []) : split(":", m)[0] if !startswith(m, "/")]
        ])) : v => {}
      }
    }))
  }

  # which secrets each VM needs = the placeholders that appear in its compose file
  vm_secrets = {
    for vm, yaml in local.compose_yaml : vm => [for name in keys(local.secret_ids) : name if strcontains(yaml, "$${${name}}")]
  }

  # secret id => the VMs that may read it
  secret_readers = merge(
    {
      for name, id in local.secret_ids : id => [for vm, names in local.vm_secrets : vm if contains(names, name)]
      if anytrue([for names in values(local.vm_secrets) : contains(names, name)])
    },
    { (local.ssh_key_secret) = [local.bastion] },
  )

  # the ports the VMs open to each other = the services' published ports
  internal_ports = sort(distinct(flatten([
    for s in values(local.services) : [for p in try(s.ports, []) : split(":", p)[0]]
  ])))
}
