#!/bin/bash
set -euo pipefail

readonly APP_DIR=/opt/citybikes
readonly CERT_SCRIPT=/usr/local/sbin/citybikes-cert
readonly SYSTEMD_DIR=/etc/systemd/system

meta() {
  curl -sf -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1" || true
}

read_secret() {
  until gcloud secrets versions access latest --secret="$1" 2>/dev/null; do
    echo "waiting for a value of the secret $1" >&2
    sleep 30
  done
}

ensure_gcloud() {
  command -v gcloud >/dev/null || snap install google-cloud-cli --classic
}

is_bastion() {
  [ -n "$(meta ssh-key-secret)" ]
}

has_services() {
  [ -n "$(meta compose)" ]
}

serves_site() {
  [ -n "$(meta tls-domain)" ]
}

install_internal_ssh_key() {
  local user home
  user=$(meta ssh-user)
  until id "$user" >/dev/null 2>&1; do sleep 5; done
  home="/home/$user"

  install -d -m 700 -o "$user" -g "$user" "$home/.ssh"
  read_secret "$(meta ssh-key-secret)" > "$home/.ssh/id_ed25519"
  chown "$user:$user" "$home/.ssh/id_ed25519"
  chmod 600 "$home/.ssh/id_ed25519"
}

install_docker() {
  command -v docker >/dev/null && return
  apt-get update
  apt-get install -y docker.io docker-compose-v2 unzip
}

install_certificate_renewal() {
  meta cert-script > "$CERT_SCRIPT"
  chmod 700 "$CERT_SCRIPT"

  cat > "$SYSTEMD_DIR/citybikes-cert.service" <<EOF
[Unit]
Description=Renew the site's TLS certificate (certbot, DNS-01)
[Service]
Type=oneshot
ExecStart=$CERT_SCRIPT
EOF

  cat > "$SYSTEMD_DIR/citybikes-cert.timer" <<'EOF'
[Timer]
OnCalendar=*-*-* 03,15:00
RandomizedDelaySec=1h
Persistent=true
[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now citybikes-cert.timer
}

obtain_certificate() {
  "$CERT_SCRIPT"
}

fetch_code() {
  rm -rf "$APP_DIR/services"
  gcloud storage cp "$(meta code)" "$APP_DIR/code.zip"
  unzip -q "$APP_DIR/code.zip" -d "$APP_DIR/services"
  rm "$APP_DIR/code.zip"
}

write_compose_file() {
  meta compose > "$APP_DIR/compose.yaml"
}

write_env_file() {
  local env_file="$APP_DIR/.env" pair
  install -m 600 /dev/null "$env_file"

  for pair in $(meta secrets); do
    echo "${pair%%=*}='$(read_secret "${pair#*=}")'" >> "$env_file"
  done

  meta env >> "$env_file"
  echo >> "$env_file"
}

start_services() {
  docker compose --project-directory "$APP_DIR" -f "$APP_DIR/compose.yaml" \
    up -d --build --remove-orphans --wait
}

main() {
  ensure_gcloud

  if is_bastion; then
    install_internal_ssh_key
  fi

  has_services || exit 0

  install_docker

  if serves_site; then
    install_certificate_renewal
    obtain_certificate
  fi

  mkdir -p "$APP_DIR"
  fetch_code
  write_compose_file
  write_env_file
  start_services
}

main "$@"
