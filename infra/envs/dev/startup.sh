#!/bin/bash

set -euo pipefail

meta() {
  curl -sf -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1" || true
}
command -v gcloud >/dev/null || snap install google-cloud-cli --classic

# For Bastion
key_secret=$(meta ssh-key-secret)
if [ -n "$key_secret" ]; then
  user=$(meta ssh-user)
  until id "$user" >/dev/null 2>&1; do sleep 5; done   
  install -d -m 700 -o "$user" -g "$user" "/home/$user/.ssh"
  gcloud secrets versions access latest --secret="$key_secret" > "/home/$user/.ssh/id_ed25519"
  chown "$user:$user" "/home/$user/.ssh/id_ed25519" && chmod 600 "/home/$user/.ssh/id_ed25519"
fi
[ -n "$(meta compose)" ] || exit 0

if ! command -v docker >/dev/null; then
  apt-get update
  apt-get install -y docker.io docker-compose-v2 unzip
fi

mkdir -p /opt/citybikes && cd /opt/citybikes
rm -rf services && gcloud storage cp "$(meta code)" code.zip
unzip -q code.zip -d services && rm code.zip
meta compose > compose.yaml

install -m 600 /dev/null .env
for pair in $(meta secrets); do           
  until value=$(gcloud secrets versions access latest --secret="${pair#*=}"); do
    echo "waiting for a value of the secret ${pair#*=}"; sleep 30
  done
  echo "${pair%%=*}='${value}'" >> .env
done

docker compose up -d --build --remove-orphans --wait
