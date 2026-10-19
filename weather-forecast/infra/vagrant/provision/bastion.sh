#!/usr/bin/env bash
source /home/vagrant/weather-staging/common.sh || exit 1

rm -f "$config/gateway-ready"
apt-get update
apt-get install -y dnsmasq nftables

internal_interface=$(ip -o -4 addr show | awk '$4 == "192.168.56.10/24" { print $2 }')
external_interface=$(ip -4 route show default | awk 'NR == 1 { print $5 }')
[[ -n "$internal_interface" && -n "$external_interface" && "$internal_interface" != "$external_interface" ]] || {
  echo 'Bastion needs an external default route and a separate 192.168.56.10/24 interface' >&2
  exit 1
}

cat > /etc/dnsmasq.d/weather.conf <<EOF
interface=$internal_interface
listen-address=192.168.56.10
bind-dynamic
domain-needed
bogus-priv
resolv-file=/run/systemd/resolve/resolv.conf
dhcp-authoritative
dhcp-range=192.168.56.0,static,255.255.255.0,12h
dhcp-option=option:router,192.168.56.10
dhcp-option=option:dns-server,192.168.56.10
dhcp-host=52:54:00:56:00:11,192.168.56.11,weather-db
dhcp-host=52:54:00:56:00:12,192.168.56.12,weather-fetcher
dhcp-host=52:54:00:56:00:13,192.168.56.13,weather-history
dhcp-host=52:54:00:56:00:14,192.168.56.14,weather-ui
EOF
dnsmasq --test

# Reload only our tables; use the distribution's existing nftables service.
cat > /etc/nftables.conf <<EOF
table inet weather_gateway {}
flush table inet weather_gateway
table inet weather_gateway {
  chain input {
    type filter hook input priority filter; policy drop;
    iifname "lo" accept
    ct state invalid drop
    ct state established,related accept
    ip protocol icmp accept
    iifname "$external_interface" udp sport 67 udp dport 68 accept
    iifname "$external_interface" tcp dport $WEATHER_SSH_PORT accept
    iifname "$internal_interface" udp sport 68 udp dport 67 accept
    iifname "$internal_interface" ip saddr 192.168.56.0/24 udp dport 53 accept
    iifname "$internal_interface" ip saddr 192.168.56.0/24 tcp dport 53 accept
  }
  chain forward {
    type filter hook forward priority filter; policy drop;
    ct state invalid drop
    ct state established,related accept
    iifname "$internal_interface" oifname "$external_interface" ip saddr 192.168.56.0/24 accept
  }
}
table ip weather_gateway_nat {}
flush table ip weather_gateway_nat
table ip weather_gateway_nat {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr 192.168.56.0/24 oifname "$external_interface" masquerade
  }
}
EOF
nft --check --file /etc/nftables.conf
printf 'net.ipv4.ip_forward = 1\n' > /etc/sysctl.d/90-weather-gateway.conf
sysctl -p /etc/sysctl.d/90-weather-gateway.conf

systemctl enable --now nftables.service
nft --file /etc/nftables.conf
systemctl enable dnsmasq.service
systemctl restart dnsmasq.service

if ! id jump >/dev/null 2>&1; then
  useradd --create-home --user-group --shell /usr/sbin/nologin jump
fi
configure_ssh ssh/bastion.conf jump
systemctl enable ssh.service
systemctl is-active --quiet ssh.service dnsmasq.service nftables.service
touch "$config/gateway-ready"
