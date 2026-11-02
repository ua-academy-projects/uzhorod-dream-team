# The services (containers) and how each one runs: the same settings as the `docker run` flags in the
# Vagrantfile, written as docker compose. Which VM runs which service is set in config.json ("vms");
# for every VM a compose file is built from this catalog and handed to the VM in its metadata.
#
# Secrets are never here: "${DB_PASSWORD}" is filled in on the VM from Secret Manager (startup.sh).
# "${DB_HOST}" too is filled in on the VM: the Cloud SQL address is known only after it is created,
# and it reaches the VM in its metadata ("env"), so the compose files are fully known at plan time.

locals {
  # where each service runs: service name => private IP of its VM (from config.json)
  at = merge([for vm, cfg in local.vms : { for s in cfg.services : s => local.ip[vm] }]...)

  # secret placeholder in compose => secret id in Secret Manager
  secret_ids = {
    DB_PASSWORD       = "${local.project.prefix}-db-password" # also the password of the Cloud SQL user
    REDIS_PASSWORD    = "${local.project.prefix}-redis-password"
    RABBITMQ_PASSWORD = "${local.project.prefix}-rabbitmq-password"
    TUNNEL_TOKEN      = "${local.project.prefix}-cloudflare-tunnel-token"
  }
  ssh_key_secret = "${local.project.prefix}-internal-ssh-key"       # read by the bastion only
  tls_secret     = "${local.project.prefix}-cloudflare-api-token"   # read by the TLS VM only (certbot DNS-01)

  # ------------------------------------------------------------ connection settings
  db_env = {
    DB_HOST     = "$${DB_HOST}" # the private IP of Cloud SQL, see the comment at the top
    DB_PORT     = "5432"
    DB_NAME     = local.app.db_name
    DB_USER     = local.app.db_user
    DB_PASSWORD = "$${DB_PASSWORD}"
    PGSSLMODE   = "require" # Cloud SQL accepts encrypted connections only (read by libpq itself)
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

  # ------------------------------------------------------------ hardening (as in the Vagrantfile)
  hardened  = { cap_drop = ["ALL"] }
  read_only = { cap_drop = ["ALL"], read_only = true, tmpfs = ["/tmp"] }

  # ------------------------------------------------------------ the catalog
  services = {
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

    # 8080 = HTTP, 8443 = HTTPS with the Let's Encrypt certificate (certbot puts it in /opt/citybikes/tls)
    ui = merge(local.hardened, {
      ports       = local.tls_on ? ["80:8080", "443:8443"] : ["80:8080"]
      volumes     = local.tls_on ? ["/opt/citybikes/tls:/etc/nginx/tls:ro"] : []
      environment = { HISTORY_URL = "http://${local.at.history}:8002" }
    })

    cloudflared = merge(local.read_only, {
      environment = {
        TUNNEL_TOKEN              = "$${TUNNEL_TOKEN}"
        TUNNEL_TRANSPORT_PROTOCOL = local.app.cloudflare_tunnel_protocol
      }
    })
  }

  # ------------------------------------------------------------ compose file per VM
  compose_defaults = {
    restart      = "unless-stopped"
    security_opt = ["no-new-privileges:true"]
  }

  # where container logs go: Cloud Logging on the VMs with "cloud_logging": true (Docker's own gcplogs
  # driver, no agent to install), elsewhere only on the VM's disk (rotated, so it never fills up)
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

  # ------------------------------------------------------------ derived from the above
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
    { for k, v in { (local.tls_secret) = [local.tls.vm] } : k => v if local.tls_on },
  )

  # the ports the VMs open to each other = the services' published ports
  internal_ports = sort(distinct(flatten([
    for s in values(local.services) : [for p in try(s.ports, []) : split(":", p)[0]]
  ])))
}
