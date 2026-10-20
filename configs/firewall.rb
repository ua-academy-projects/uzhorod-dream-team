FIREWALL_RULES = [
  {
    to: "*",
    from: {
      host: ENV.fetch("VAGRANT_NAT_GATEWAY", "10.0.2.2"),
      ports: [22]
    },
    interface: "eth0"
  },
  {
    to: "*",
    from: {
      host: ENV["BASTION_HOST"],
      ports: [22]
    },
    interface: "eth1"
  },
  {
    to: "fetcher",
    from: {
      host: ENV["DATABASE_HOST"],
      ports: [22]
    }
  },
  {
    to: "history",
    from: {
      host: ENV["DATABASE_HOST"],
      ports: [22]
    }
  },
  {
    to: "frontend",
    from: {
      host: ENV["DATABASE_HOST"],
      ports: [22]
    }
  },
  {
    to: "database",
    from: {
      host: ENV["BASTION_HOST"],
      ports: [
        ENV["DATABASE_PORT"].to_i,
        ENV["RABBITMQ_PORT"].to_i,
        ENV["RABBITMQ_MANAGEMENT_PORT"].to_i,
        ENV["REDIS_PORT"].to_i
      ]
    },
    docker: true
  },
  {
    to: "database",
    from: {
      host: ENV["FETCHER_HOST"],
      ports: [
        ENV["DATABASE_PORT"].to_i,
        ENV["RABBITMQ_PORT"].to_i
      ]
    },
    docker: true
  },
  {
    to: "database",
    from: {
      host: ENV["HISTORY_HOST"],
      ports: [
        ENV["DATABASE_PORT"].to_i,
        ENV["RABBITMQ_PORT"].to_i,
        ENV["REDIS_PORT"].to_i
      ]
    },
    docker: true
  },
  {
    to: "fetcher",
    from: {
      host: ENV["HISTORY_HOST"],
      ports: [ENV["FETCHER_PORT"].to_i]
    },
    docker: true
  },
  {
    to: "history",
    from: {
      host: ENV["FRONTEND_HOST"],
      ports: [ENV["HISTORY_PORT"].to_i]
    },
    docker: true
  },
  {
    to: "frontend",
    from: {
      host: ENV["BASTION_HOST"],
      ports: [ENV["FRONTEND_PORT"].to_i]
    },
    docker: true
  },
]