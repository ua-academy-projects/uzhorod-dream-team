#!/usr/bin/env bash
set -Eeuo pipefail

# A standalone bounded probe used both during provisioning and by systemd on boot.
# PostgreSQL readiness is followed by authenticated migrations during provisioning.
kind=$1
target=$2
port=$3
timeout=$4
deadline=$((SECONDS + timeout))
while (( SECONDS < deadline )); do
  case "$kind" in
    http)
      if curl -fsS --connect-timeout 2 --max-time 3 "$target" >/dev/null 2>&1; then
        exit 0
      fi
      ;;
    postgres)
      if pg_isready -q -h "$target" -p "$port" -t 3; then
        exit 0
      fi
      ;;
    tcp)
      remaining=$((deadline - SECONDS))
      (( remaining > 3 )) && remaining=3
      if timeout "${remaining}s" bash -c 'exec 3<>"/dev/tcp/$1/$2"' bash "$target" "$port" 2>/dev/null; then
        exit 0
      fi
      ;;
    *) echo "Unknown readiness probe: $kind" >&2; exit 1 ;;
  esac
  sleep 1
done
echo "Timed out waiting for $kind at $target (port $port). Start the dependency VM first, check its logs/firewall, then reprovision or restart this service." >&2
exit 1
