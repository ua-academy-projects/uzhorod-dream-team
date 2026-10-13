# Shared helpers for role scripts.

# Writes the named variables to a 0600 file for docker --env-file, so secret
# values never show up on a command line (ps, sudo's journal).
env_file() {
  local file=$1 name
  shift
  (
    umask 077
    for name in "$@"; do printf '%s=%s\n' "$name" "${!name:?$name is not set}"; done > "$file"
  )
}

# Replace a running container with a fresh one. A graceful stop first:
# Postgres and Redis get to flush instead of being killed.
replace() {
  local name=$1
  shift
  sudo docker stop -t 30 "$name" >/dev/null 2>&1 || true
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

# Block until host:port accepts TCP. Machines provision in parallel, and db may
# still be building its image: allow up to 5 minutes.
wait_port() {
  for _ in $(seq 1 150); do
    timeout 2 bash -c "echo > /dev/tcp/$1/$2" 2>/dev/null && return 0
    sleep 2
  done
  echo "$1:$2 unreachable" >&2
  return 1
}
