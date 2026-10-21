#!/usr/bin/env bash
set -euo pipefail

apt-get update -qq && apt-get install -y -qq nftables nginx

# the bastion reaches the outside via dmz, not via mgmt
cat >/etc/systemd/system/default-route.service <<'EOF'
[Unit]
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/sbin/ip route replace default via 192.168.50.1
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable --now default-route

# NAT instance for the private network
echo 'net.ipv4.ip_forward=1' >/etc/sysctl.d/99-forward.conf
sysctl --system >/dev/null

MGMT_IF=$(ip -o -4 addr show | awk '/192\.168\.121\./{print $2}')

# NAT for the private subnet + "Security Group": SSH and HTTP only from the dmz subnet (+ the management SSH from Vagrant
# and SSH from the log collector on db)
cat >/etc/nftables.conf <<EOF
table ip nat {
  chain postrouting {
    type nat hook postrouting priority 100;
    ip saddr 10.10.0.0/24 ip daddr != 10.10.0.0/24 masquerade
  }
}
table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;
    ct state established,related accept
    iif lo accept
    iifname "$MGMT_IF" ip saddr 192.168.121.1 tcp dport 22 accept
    ip saddr 192.168.50.0/24 tcp dport { 22, 80 } accept
    ip saddr 10.10.0.25 tcp dport 22 accept
    ip saddr { 192.168.50.0/24, 10.10.0.0/24 } icmp type echo-request accept
  }
}
EOF
systemctl enable nftables && systemctl restart nftables

# SSH hardening
cat >/etc/ssh/sshd_config.d/10-bastion.conf <<'EOF'
PasswordAuthentication no
PermitRootLogin no
AllowAgentForwarding no
EOF
systemctl reload ssh
# Reverse proxy: the single entry point from outside. The browser talks only to this nginx (same origin):
#   /            -> frontend VM (static files)
#   /api/pois    -> fetcher GET /pois (the only API call the UI needs)
#   /api/healthz -> fetcher GET /healthz
rm -f /etc/nginx/sites-enabled/default
cat >/etc/nginx/conf.d/edge.conf <<'CONF'
# Requests that come through the Cloudflare Tunnel arrive from 127.0.0.1: take the visitor's address from the header,
# but only from that trusted local source (anyone else sending the header is ignored). Keeps limit_req per visitor.
set_real_ip_from 127.0.0.1;
real_ip_header CF-Connecting-IP;

# Overpass is fragile and every cache miss is expensive, so keep the request rate low
limit_req_zone $binary_remote_addr zone=api:10m rate=30r/m;
limit_req_status 429;

server {
  listen 80 default_server;

  # besides the files, nginx logs go to journald (tags nginx_access / nginx_error) where the log collector on db picks them up
  access_log /var/log/nginx/access.log;
  access_log syslog:server=unix:/dev/log,tag=nginx_access,nohostname;
  error_log syslog:server=unix:/dev/log,tag=nginx_error,nohostname;

  location / {
    limit_except GET HEAD { deny all; }
    proxy_pass http://10.10.0.20:80;
  }

  location = /api/pois {
    limit_except GET { deny all; }
    limit_req zone=api burst=10 nodelay;
    # the fetcher may go through all Overpass endpoints before it answers
    proxy_read_timeout 90s;
    proxy_pass http://10.10.0.21:8080/pois;
  }

  location = /api/healthz {
    limit_except GET { deny all; }
    proxy_pass http://10.10.0.21:8080/healthz;
  }

  location /api/ { return 404; }
}
CONF
nginx -t
systemctl enable nginx
systemctl reload nginx || systemctl restart nginx
