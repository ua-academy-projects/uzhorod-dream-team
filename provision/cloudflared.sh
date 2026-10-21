#!/usr/bin/env bash
# Cloudflare Tunnel on the bastion: publishes the nginx (localhost:80) at the public hostname configured for the tunnel in
# the Cloudflare dashboard, over an outbound-only connection (no inbound port is opened). The script is idempotent.
# The tunnel token is optional: Vagrant uploads deploy/cloudflared.env to /tmp/cloudflared.env when it exists; without it
# only the binary and the unit are installed and the service stays stopped.
set -euo pipefail

VERSION=2026.10.2
SHA256=30a9a127c24ea8365fa8e11b13684128f34dd8a1137599aa00b4bebda1a0a083

# cloudflared is not packaged in Debian, so take the pinned release .deb from GitHub and verify it
if [ "$(cloudflared --version 2>/dev/null | awk '{print $3}')" != "$VERSION" ]; then
  deb=$(mktemp --suffix=.deb)
  trap 'rm -f "$deb"' EXIT
  wget -q -O "$deb" "https://github.com/cloudflare/cloudflared/releases/download/$VERSION/cloudflared-linux-amd64.deb"
  echo "$SHA256  $deb" | sha256sum -c - >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$deb"
fi

# http2 (TCP 7844) instead of the default QUIC (UDP 7844): works on networks that filter UDP
cat >/etc/systemd/system/cloudflared.service <<'UNIT'
[Unit]
Description=Cloudflare Tunnel
After=network-online.target
Wants=network-online.target

[Service]
EnvironmentFile=/etc/cloudflared.env
ExecStart=/usr/bin/cloudflared --no-autoupdate tunnel --protocol http2 run
Restart=on-failure
RestartSec=5
DynamicUser=yes
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload

if [ -f /tmp/cloudflared.env ]; then
  install -m600 /tmp/cloudflared.env /etc/cloudflared.env
  rm -f /tmp/cloudflared.env
  systemctl enable cloudflared
  systemctl restart cloudflared
elif [ -f /etc/cloudflared.env ]; then
  systemctl enable cloudflared
  systemctl restart cloudflared
else
  echo "cloudflared: no deploy/cloudflared.env (TUNNEL_TOKEN), the service is installed but not started" >&2
fi
