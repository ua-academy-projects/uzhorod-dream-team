
#!/usr/bin/env bash
set -euo pipefail

SERVICE_ROLE="${1:?Specify service role}"

REPO_URL="https://github.com/ua-academy-projects/uzhorod-dream-team.git"
REPO_BRANCH="dmytro/btc-eth-price-analyzer"

APP_DIR="/opt/datamonitor"
COMPOSE_DIR="${APP_DIR}/DataFetcher"

case "${SERVICE_ROLE}" in
    database|fetcher|history|ui)
        ;;
    *)
        echo "ERROR: Unknown service role: ${SERVICE_ROLE}"
        exit 1
        ;;
esac

echo "=== Deploying ${SERVICE_ROLE} ==="


if ! command -v git >/dev/null 2>&1; then
    apt-get update
    apt-get install -y git
fi


if [[ -d "${APP_DIR}/.git" ]]; then
    git -C "${APP_DIR}" fetch origin "${REPO_BRANCH}"
    git -C "${APP_DIR}" checkout "${REPO_BRANCH}"
    git -C "${APP_DIR}" pull --ff-only origin "${REPO_BRANCH}"
else
    git clone \
        --branch "${REPO_BRANCH}" \
        --single-branch \
        "${REPO_URL}" \
        "${APP_DIR}"
fi


if [[ ! -d "${COMPOSE_DIR}" ]]; then
    echo "ERROR: Project directory not found: ${COMPOSE_DIR}"
    exit 1
fi

cd "${COMPOSE_DIR}"


if ! docker compose version >/dev/null 2>&1; then
    echo "ERROR: Docker Compose is not installed"
    exit 1
fi

if [[ ! -f .env ]]; then
    echo "ERROR: ${COMPOSE_DIR}/.env is missing"
    exit 1
fi

docker compose \
    --env-file .env \
    -f docker-compose.yml \
    --profile "${SERVICE_ROLE}" \
    up -d --build

echo "=== Deployment completed: ${SERVICE_ROLE} ==="
