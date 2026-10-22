#!/usr/bin/env bash
# Collects docker logs of all project containers from the three VMs into this project folder:
#   logs/<UTC date-time>/<VM name>/<container>.log
# Run from WSL (from any folder):
#   ./scripts/collect-logs.sh
# It uses "ssh weather/fetcher/history" (own key, see README). The key must be unlocked:
# ssh-agent, or ssh asks the passphrase once per VM.
# Only the last 24 hours, stdout and stderr together, each line with a Docker timestamp.
# If a VM or a container is not reachable, the others are still collected,
# and the script ends with exit code 1 and a list of what is missing.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

SINCE=24h

# VM -> its short SSH name and the provisioning scripts that start its containers.
# Container names are taken from the line CONTAINER=... of these scripts,
# so they stay the same as in the code that creates the containers.
VMS=(weather-vm fetcher-vm history-vm)
declare -A SSH_HOST=([weather-vm]=weather [fetcher-vm]=fetcher [history-vm]=history)
declare -A SCRIPTS=(
  [weather-vm]="provision/broker.sh provision/cache.sh"
  [fetcher-vm]="provision/fetcher.sh"
  [history-vm]="provision/history.sh"
)

# Safety net: if a program ever writes a URL with a password (scheme://user:password@host),
# the password is replaced with *** before the line is saved.
redact() {
  sed -E 's#([A-Za-z][A-Za-z0-9+.-]*://[^/:@[:space:]]*:)[^@[:space:]]+@#\1***@#g'
}

out="logs/$(date -u +%Y%m%dT%H%M%SZ)"
# Logs are readable only for this user of WSL.
umask 077
mkdir -p "$out"

# One SSH connection per VM for all its containers (ControlMaster),
# so the passphrase is asked at most once per VM.
control_dir=$(mktemp -d)
trap 'for h in "${SSH_HOST[@]}"; do ssh -o ControlPath="$control_dir/%n" -O exit "$h" 2>/dev/null; done; rm -rf "$control_dir"' EXIT
ssh_vm() {
  ssh -o ConnectTimeout=10 -o ControlMaster=auto -o ControlPath="$control_dir/%n" \
    -o ControlPersist=60 "$@"
}

missing=()
saved=0

for vm in "${VMS[@]}"; do
  host=${SSH_HOST[$vm]}
  containers=$(sed -n 's/^CONTAINER=//p' ${SCRIPTS[$vm]})

  if ! ssh_vm "$host" true 2>/dev/null; then
    echo "$vm: not reachable with \"ssh $host\" — skipped"
    missing+=("$vm (VM not reachable)")
    continue
  fi
  mkdir -p "$out/$vm"

  for container in $containers; do
    file="$out/$vm/$container.log"
    # 2>&1 runs inside the VM: stdout and stderr of the container go into the same file,
    # errors of ssh itself stay on the terminal.
    if ssh_vm "$host" "sudo -n docker logs --timestamps --since $SINCE $container 2>&1" \
         | redact > "$file"; then
      echo "$vm: $container — $(wc -l < "$file") lines"
      saved=$((saved + 1))
    else
      echo "$vm: $container — logs not read (container missing?)"
      missing+=("$vm/$container")
      # The file holds the error text of docker (for example "No such container").
      mv "$file" "$file.error"
    fi
  done
done

echo "Saved $saved files in $out/"
if (( ${#missing[@]} > 0 )); then
  echo "INCOMPLETE: not collected: ${missing[*]}" >&2
  exit 1
fi
