# Shared helpers for role scripts.

# Replace a running container with a fresh one.
replace() {
  local name=$1; shift
  sudo docker rm -f "$name" >/dev/null 2>&1 || true
  sudo docker run -d --name "$name" --restart unless-stopped "$@"
}

# Block until the container's HEALTHCHECK reports healthy.
wait_healthy() {
  local name=$1
  for _ in $(seq 1 60); do
    [ "$(sudo docker inspect -f '{{.State.Health.Status}}' "$name" 2>/dev/null)" = healthy ] && return 0
    sleep 2
  done
  echo "$name is not healthy" >&2
  sudo docker logs --tail 20 "$name" >&2
  return 1
}

# Block until host:port accepts TCP.
wait_port() {
  for _ in $(seq 1 90); do
    (echo > "/dev/tcp/$1/$2") 2>/dev/null && return 0
    sleep 2
  done
  echo "$1:$2 unreachable" >&2
  return 1
}