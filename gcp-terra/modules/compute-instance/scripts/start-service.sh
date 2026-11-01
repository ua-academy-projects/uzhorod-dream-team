
#!/usr/bin/env bash
set -euo pipefail

ROLE="${1:?Missing service role}"
PROJECT_ID="${2:?Missing GCP project ID}"
TUNNEL_SECRET_ID="${3:-}"
IP_HTTPS="${4:-false}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${ROLE}" in
  database|fetcher|history|ui) ;;
  *)
    echo "ERROR: Invalid service role: ${ROLE}"
    exit 1
    ;;
esac

echo "=== Starting Data Monitor: ${ROLE} ==="

# 1. Install Docker
bash "${SCRIPT_DIR}/install-docker.sh"

# 2. Install deployment dependencies
export DEBIAN_FRONTEND=noninteractive
apt-get install -y git curl python3

# 3. Clone or update project
APP_DIR="/opt/datamonitor"
REPO_URL="https://github.com/ua-academy-projects/uzhorod-dream-team.git"
BRANCH="dmytro/btc-eth-price-analyzer"

if [[ -d "${APP_DIR}/.git" ]]; then
  git -C "${APP_DIR}" fetch origin "${BRANCH}"
  git -C "${APP_DIR}" checkout "${BRANCH}"
  git -C "${APP_DIR}" pull --ff-only origin "${BRANCH}"
else
  git clone --branch "${BRANCH}" --single-branch \
    "${REPO_URL}" "${APP_DIR}"
fi

COMPOSE_DIR="${APP_DIR}/DataFetcher"

if [[ ! -f "${COMPOSE_DIR}/docker-compose.yml" ]]; then
  echo "ERROR: docker-compose.yml not found"
  exit 1
fi

# 4. Get VM service account access token
METADATA_URL="http://metadata.google.internal/computeMetadata/v1"

get_token() {
  curl --fail --silent --show-error \
    -H "Metadata-Flavor: Google" \
    "${METADATA_URL}/instance/service-accounts/default/token" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])'
}

# 5. Download .env from Secret Manager
SECRET_URL="https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}/secrets/datamonitor-env/versions/latest:access"

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

# Use the Compose and Nginx configuration embedded by Terraform.
install -d "${SCRIPT_DIR}/nginx"
install -m 644 "${SCRIPT_DIR}/nginx.conf" "${SCRIPT_DIR}/nginx/default.conf"
export NGINX_CONFIG_DIR="${SCRIPT_DIR}/nginx"

COMPOSE_EXTRA_ARGS=()
if [[ "${ROLE}" == ui && -n "${TUNNEL_SECRET_ID}" ]]; then
  [[ "${TUNNEL_SECRET_ID}" =~ ^[a-zA-Z0-9_-]+$ ]] || exit 1
  install -d -m 700 /opt/datamonitor-secrets
  TUNNEL_FILE=/opt/datamonitor-secrets/cloudflare-tunnel-token
  TUNNEL_TMP="$(mktemp /opt/datamonitor-secrets/tunnel.XXXXXX)"
  trap 'rm -f "${TMP_FILE}" "${TUNNEL_TMP}"' EXIT
  TOKEN="$(get_token)"
  curl --fail --silent --show-error --retry 5 --retry-all-errors --max-time 30 \
    -H "Authorization: Bearer ${TOKEN}" \
    "https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}/secrets/${TUNNEL_SECRET_ID}/versions/latest:access" |
    python3 -c 'import base64,json,sys; sys.stdout.buffer.write(base64.b64decode(json.load(sys.stdin)["payload"]["data"]))' > "${TUNNEL_TMP}"
  test -s "${TUNNEL_TMP}"
  chown 65532:65532 "${TUNNEL_TMP}"
  chmod 400 "${TUNNEL_TMP}"
  mv -f "${TUNNEL_TMP}" "${TUNNEL_FILE}"
  unset TOKEN
  export CLOUDFLARE_TUNNEL_TOKEN_FILE="${TUNNEL_FILE}"
  export COOKIE_SECURE=true
  COMPOSE_EXTRA_ARGS=(--profile tunnel)
fi

if [[ "${ROLE}" == ui && "${IP_HTTPS}" == true ]]; then
  export COOKIE_SECURE=true
  bash "${SCRIPT_DIR}/setup-ui-https.sh"
  export UI_HTTP_BIND=0.0.0.0:80
  export UI_HTTPS_BIND=0.0.0.0:443
fi

# 6. Start Docker Compose
cd "${COMPOSE_DIR}"

docker compose \
  --env-file .env \
  --project-directory "${COMPOSE_DIR}" \
  -f "${SCRIPT_DIR}/compose.yml" \
  --profile "${ROLE}" "${COMPOSE_EXTRA_ARGS[@]}" \
  up -d --build


if [[ "${ROLE}" == "database" ]]; then
  set -a
  source "${ENV_FILE}"
  set +a

  for attempt in $(seq 1 60); do
    if docker exec datamonitor-postgres \
      pg_isready -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
      >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done

  docker exec -i datamonitor-postgres \
    psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
    -v ON_ERROR_STOP=1 \
    -v "worker_password=${FETCHER_POSTGRES_PASSWORD}" <<'SQL'
ALTER ROLE fetcher_worker WITH LOGIN PASSWORD :'worker_password';
SQL
fi

echo "=== Deployment completed: ${ROLE} ==="
