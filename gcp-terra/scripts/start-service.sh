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

ENV_SERVICE="$ROLE"
if [[ "$ROLE" == database ]]; then ENV_SERVICE=postgres; fi
export ENV_FILE="${COMPOSE_DIR}/${ENV_SERVICE}/.env"
TMP_FILE="$(mktemp "${ENV_FILE}.XXXXXX")"
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

# Filter the shared definition before interpolation: this VM has no other secrets.
install -d -m 700 /var/lib/datamonitor
export COMPOSE_FILE_PATH="/var/lib/datamonitor/compose.${ROLE}.yaml"
python3 "${SCRIPT_DIR}/select-compose.py" "${COMPOSE_DIR}/docker-compose.yml" "$ROLE" > "$COMPOSE_FILE_PATH"
chmod 600 "$COMPOSE_FILE_PATH"
# The legacy shared env is no longer read by this deployment.
rm -f "${COMPOSE_DIR}/.env"

# Terraform deployment settings override stale routing values in the secret.
: "${APP_BACKEND:?Missing configured app_backend; apply Terraform first}"
: "${DATABASE_PROVIDER:?Missing configured database provider; apply Terraform first}"
case "$APP_BACKEND" in hybrid|postgres) ;; *) echo 'Invalid APP_BACKEND' >&2; exit 1 ;; esac
case "$DATABASE_PROVIDER" in cloud_sql|container) ;; *) echo 'Invalid DATABASE_PROVIDER' >&2; exit 1 ;; esac
: "${DATABASE_HOST:?Missing configured database host}"
: "${DATABASE_NAME:?Missing configured database name}"
: "${INSTANCE_CONNECTION_NAME?Missing configured Cloud SQL connection name}"
export APP_BACKEND INSTANCE_CONNECTION_NAME
export POSTGRES_HOST="$DATABASE_HOST" FETCHER_POSTGRES_HOST="$DATABASE_HOST"
export POSTGRES_DB="$DATABASE_NAME" FETCHER_POSTGRES_DB="$DATABASE_NAME"
if [[ "$DATABASE_PROVIDER" == container ]]; then
  export INSTANCE_CONNECTION_NAME=""
fi

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
  echo "=== Deployment completed: ${ROLE} ==="
  exit 0
fi

# Start the services from the same checkout as their deployment scripts.
cd "${COMPOSE_DIR}"

SERVICES=()
if [[ "${ROLE}" == database ]]; then
  STOP_SERVICES=()
  if [[ "$DATABASE_PROVIDER" == container ]]; then
    SERVICES+=(postgres)
  else
    STOP_SERVICES+=(postgres)
  fi
  if [[ "$APP_BACKEND" == hybrid ]]; then
    SERVICES+=(rabbitmq redis)
  else
    STOP_SERVICES+=(rabbitmq redis)
  fi
  for service in "${STOP_SERVICES[@]}"; do
    if docker inspect "datamonitor-$service" >/dev/null 2>&1; then
      docker stop "datamonitor-$service"
    fi
  done
  if [[ ${#SERVICES[@]} == 0 ]]; then
    echo 'Cloud SQL postgres mode requires no database VM containers.'
    exit 0
  fi
fi

docker compose \
  --env-file "${ENV_FILE}" \
  --project-directory "${COMPOSE_DIR}" \
  -f "${COMPOSE_FILE_PATH}" \
  --profile "${ROLE}" \
  up -d "${COMPOSE_BUILD_ARGS[@]}" "${SERVICES[@]}"

echo "=== Deployment completed: ${ROLE} ==="
