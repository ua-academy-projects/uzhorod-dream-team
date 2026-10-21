#!/usr/bin/env bash
set -euo pipefail

# install packages WHILE the internet is still reachable via mgmt
apt-get update -qq && apt-get install -y -qq nftables

MGMT_IF=$(ip -o -4 addr show | awk '/192\.168\.121\./{print $2}')

# from now on the internet is reachable only via the bastion
cat >/etc/systemd/system/default-route.service <<'EOF'
[Unit]
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/sbin/ip route replace default via 10.10.0.10
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable --now default-route

# fetcher (.21) and history (.22) talk to db (Postgres/pgmq) and mq (RabbitMQ); only the fetcher needs the Redis cache
case "$ROLE" in
  db)       EXTRA='ip saddr { 10.10.0.21, 10.10.0.22 } tcp dport 5432 accept' ;;
  mq)       EXTRA='ip saddr { 10.10.0.21, 10.10.0.22 } tcp dport 5672 accept
    ip saddr 10.10.0.21 tcp dport 6379 accept' ;;
  frontend) EXTRA='ip saddr 10.10.0.10 tcp dport 80 accept' ;;   # static site: bastion (nginx) only
  # fetcher API / history /healthz and /stats: bastion only; SSH also from the log collector (db)
  fetcher)  EXTRA='ip saddr 10.10.0.10 tcp dport 8080 accept
    ip saddr 10.10.0.25 tcp dport 22 accept' ;;
  history)  EXTRA='ip saddr 10.10.0.10 tcp dport 8081 accept
    ip saddr 10.10.0.25 tcp dport 22 accept' ;;
  *)        EXTRA="" ;;
esac

# "Security Group": SSH only from the bastion (+ the management SSH from Vagrant)
cat >/etc/nftables.conf <<EOF
table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;
    ct state established,related accept
    iif lo accept
    iifname "$MGMT_IF" ip saddr 192.168.121.1 tcp dport 22 accept
    ip saddr 10.10.0.10 tcp dport 22 accept
    ip saddr 10.10.0.0/24 icmp type echo-request accept
    $EXTRA
  }
}
EOF
systemctl enable nftables && systemctl restart nftables