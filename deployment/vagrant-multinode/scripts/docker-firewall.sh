#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/kyiv-air/firewall.env

for command in iptables ip6tables; do
  "$command" -w -N KYIV-AIR-HOST 2>/dev/null || true
  "$command" -w -F KYIV-AIR-HOST
  "$command" -w -C INPUT -j KYIV-AIR-HOST 2>/dev/null || "$command" -w -I INPUT 1 -j KYIV-AIR-HOST
  "$command" -w -A KYIV-AIR-HOST -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  "$command" -w -A KYIV-AIR-HOST -i lo -j ACCEPT
  # SSH
  "$command" -w -A KYIV-AIR-HOST -p tcp --dport 22 -j ACCEPT
done

# DHCP
iptables -w -A KYIV-AIR-HOST -p icmp -j ACCEPT
iptables -w -A KYIV-AIR-HOST -p udp --sport 67 --dport 68 -j ACCEPT
ip6tables -w -A KYIV-AIR-HOST -p ipv6-icmp -j ACCEPT
ip6tables -w -A KYIV-AIR-HOST -p udp --sport 547 --dport 546 -j ACCEPT

iptables -w -A KYIV-AIR-HOST -j DROP
ip6tables -w -A KYIV-AIR-HOST -j DROP

iptables -w -N DOCKER-USER 2>/dev/null || true
iptables -w -N KYIV-AIR 2>/dev/null || true
iptables -w -F KYIV-AIR
iptables -w -C DOCKER-USER -o kyiv-air0 -j KYIV-AIR 2>/dev/null ||
  iptables -w -I DOCKER-USER 1 -o kyiv-air0 -j KYIV-AIR
iptables -w -A KYIV-AIR -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
iptables -w -A KYIV-AIR -i kyiv-air0 -j RETURN

allow_port() {
  iptables -w -A KYIV-AIR -p tcp -s "$1" -m conntrack --ctorigdst "$PRIVATE_IP" --ctorigdstport "$2" -j RETURN
}

case "$ROLE" in
  db)
    allow_port "$PRIVATE_SUBNET" 5432
    allow_port "$HISTORY_IP" 6379
    allow_port "$FETCHER_IP" 5672
    allow_port "$HISTORY_IP" 5672
    ;;
  fetcher|history)
    allow_port "$PRIVATE_SUBNET" "$SERVICE_PORT"
    ;;
  ui)
    allow_port "$BASTION_IP" "$SERVICE_PORT"
    ;;
  bastion)
    iptables -w -A KYIV-AIR -p tcp -m conntrack --ctorigdst "$PUBLIC_IP" --ctorigdstport "$SERVICE_PORT" -j RETURN
    ;;
  *) echo "Unknown firewall role: $ROLE" >&2; exit 1 ;;
esac
iptables -w -A KYIV-AIR -j DROP
