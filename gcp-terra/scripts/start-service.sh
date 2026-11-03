#!/usr/bin/env bash
set -euo pipefail

ROLE="${SERVICE_ROLE:?Missing service role}"
: "${PROJECT_ID:?Missing GCP project ID}"
: "${ENV_SECRET_ID:?Missing environment secret ID}"
IP_HTTPS="${IP_HTTPS:-false}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="$(cd "${SCRIPT_DIR}/../../DataFetcher" && pwd)"

case "${ROLE}" in
  database|fetcher|history|ui) ;;
  *)
    echo "ERROR: Invalid service role: ${ROLE}"
    exit 1
    ;;
esac

echo "=== Starting Data Monitor: ${ROLE} ==="

# Get the attached VM service account access token.
METADATA_URL="http://metadata.google.internal/computeMetadata/v1"

get_token() {
  curl --fail --silent --show-error \
    -H "Metadata-Flavor: Google" \
    "${METADATA_URL}/instance/service-accounts/default/token" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])'
}

# Refresh the environment from Secret Manager.
SECRET_URL="https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}/secrets/${ENV_SECRET_ID}/versions/latest:access"

ENV_FILE="${COMPOSE_DIR}/.env"
TMP_FILE="$(mktemp "${COMPOSE_DIR}/.env.XXXXXX")"
chmod 600 "${TMP_FILE}"

cleanup() {
  rm -f "${TMP_FILE}"
}
trap cleanup EXIT

echo "Downloading environment configuration..."

SUCCESS=false

for attempt in $(seq 1 12); do
  if TOKEN="$(get_token)"; then
    if curl --fail --silent --show-error \
      -H "Authorization: Bearer ${TOKEN}" \
      "${SECRET_URL}" |
      python3 -c '
import base64,json,sys
data=json.load(sys.stdin)["payload"]["data"]
sys.stdout.buffer.write(base64.b64decode(data))
' > "${TMP_FILE}"; then
      if [[ -s "${TMP_FILE}" ]]; then
        SUCCESS=true
        break
      fi
    fi
  fi

  echo "Secret download attempt ${attempt} failed"
  sleep 10
done

if [[ "${SUCCESS}" != "true" ]]; then
  echo "ERROR: Unable to download Secret Manager configuration"
  exit 1
fi

mv -f "${TMP_FILE}" "${ENV_FILE}"
chmod 600 "${ENV_FILE}"

COMPOSE_BUILD_ARGS=(--no-build)
if [[ "${BUILD_IMAGES:-false}" == true ]]; then
  COMPOSE_BUILD_ARGS=(--build)
fi
if [[ "${ROLE}" == ui ]]; then
  export NGINX_CONFIG_DIR=/var/lib/datamonitor/nginx
  install -d "${NGINX_CONFIG_DIR}"
  install -m 644 "${COMPOSE_DIR}/nginx/default.conf" "${NGINX_CONFIG_DIR}/default.conf"
fi

if [[ "${ROLE}" == ui && "${IP_HTTPS}" == true ]]; then
  export COOKIE_SECURE=true
  bash "${SCRIPT_DIR}/setup-ui-https.sh"
  export UI_HTTP_BIND=0.0.0.0:80
  export UI_HTTPS_BIND=0.0.0.0:443
fi

# Start the services from the same checkout as their deployment scripts.
cd "${COMPOSE_DIR}"

# Cloud deployments keep RabbitMQ/Redis here; PostgreSQL lives in Cloud SQL.
SERVICES=()
if [[ "${ROLE}" == database ]]; then
  SERVICES=(rabbitmq redis)
fi

docker compose \
  --env-file .env \
  --project-directory "${COMPOSE_DIR}" \
  -f "${COMPOSE_DIR}/docker-compose.yml" \
  --profile "${ROLE}" \
  up -d "${COMPOSE_BUILD_ARGS[@]}" "${SERVICES[@]}"

echo "=== Deployment completed: ${ROLE} ==="
