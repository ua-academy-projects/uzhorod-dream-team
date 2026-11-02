#!/bin/bash
set -euo pipefail

readonly LE_DIR=/etc/letsencrypt
readonly NGINX_TLS_DIR=/opt/citybikes/tls
readonly CERTBOT_IMAGE=certbot/dns-cloudflare:v3.0.1
readonly CLOUDFLARE_INI=cloudflare.ini
readonly NGINX_UID=101

meta() {
  curl -sf -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1" || true
}

read_secret() {
  local name=$1 value
  until value=$(gcloud secrets versions access latest --secret="$name" 2>/dev/null); do
    echo "waiting for a value of the secret $name" >&2
    sleep 30
  done
  printf '%s' "$value"
}

write_cloudflare_credentials() {
  local token
  token=$(read_secret "$(meta tls-token-secret)")
  install -d -m 700 "$LE_DIR"
  (umask 077; printf 'dns_cloudflare_api_token = %s\n' "$token" > "$LE_DIR/$CLOUDFLARE_INI")
}

certbot() {
  docker run --rm -v "$LE_DIR:/etc/letsencrypt" "$CERTBOT_IMAGE" "$@"
}

has_certificate() {
  [ -f "$LE_DIR/live/$DOMAIN/fullchain.pem" ]
}

issue_certificate() {
  local args=(
    certonly --non-interactive --agree-tos -d "$DOMAIN"
    --dns-cloudflare
    --dns-cloudflare-credentials "/etc/letsencrypt/$CLOUDFLARE_INI"
    --dns-cloudflare-propagation-seconds 30
  )
  if [ -n "$EMAIL" ]; then
    args+=(-m "$EMAIL")
  else
    args+=(--register-unsafely-without-email)
  fi
  if [ "$STAGING" = "true" ]; then
    args+=(--staging)
  fi
  certbot "${args[@]}"
}

renew_certificate() {
  certbot renew --non-interactive
}

certificate_changed() {
  ! cmp -s "$LE_DIR/live/$DOMAIN/fullchain.pem" "$NGINX_TLS_DIR/fullchain.pem"
}

install_certificate_for_nginx() {
  install -d -m 755 "$NGINX_TLS_DIR"
  install -m 644 "$LE_DIR/live/$DOMAIN/fullchain.pem" "$NGINX_TLS_DIR/fullchain.pem"
  install -m 600 -o "$NGINX_UID" -g "$NGINX_UID" "$LE_DIR/live/$DOMAIN/privkey.pem" "$NGINX_TLS_DIR/privkey.pem"
}

write_nginx_https_config() {
  cat > "$NGINX_TLS_DIR/https.conf" <<'EOF'
listen 8443 ssl;
ssl_certificate     /etc/nginx/tls/fullchain.pem;
ssl_certificate_key /etc/nginx/tls/privkey.pem;
ssl_protocols       TLSv1.2 TLSv1.3;
EOF
}

reload_nginx() {
  docker exec ui nginx -s reload 2>/dev/null || true
}

main() {
  DOMAIN=$(meta tls-domain)
  EMAIL=$(meta tls-email)
  STAGING=$(meta tls-staging)

  write_cloudflare_credentials

  if has_certificate; then
    renew_certificate
  else
    issue_certificate
  fi

  if certificate_changed; then
    install_certificate_for_nginx
    write_nginx_https_config
    reload_nginx
    echo "certificate for $DOMAIN installed"
  fi
}

main "$@"