
#!/usr/bin/env bash
set -euo pipefail

# Запускати з кореня проєкту, де лежить Vagrantfile.
ROOT="$(pwd)"
LOGGING="$ROOT/provision/logging"

echo "Checking Vagrant machines..."

for vm in history fetcher postgres ui; do
  vagrant status "$vm"
done

echo "Creating persistent SSH key on History..."

vagrant ssh history -c \
  "sudo install -d -m 700 /root/.ssh &&
   if ! sudo test -f /root/.ssh/history_log_collector; then
     sudo ssh-keygen -q -t ed25519 \
       -f /root/.ssh/history_log_collector -N '' \
       -C history-log-collector
   fi &&
   sudo chmod 600 /root/.ssh/history_log_collector"

PUBKEY="$(
  vagrant ssh history -c \
    "sudo cat /root/.ssh/history_log_collector.pub" |
    tr -d '\r' | grep '^ssh-ed25519 ' | tail -n 1
)"

if [[ -z "$PUBKEY" ]]; then
  echo "ERROR: Could not retrieve History public key."
  exit 1
fi

echo "Installing public key on remote VMs..."

for vm in fetcher postgres ui; do
  vagrant ssh "$vm" -c \
    "sudo install -d -m 700 -o vagrant -g vagrant /home/vagrant/.ssh &&
     sudo touch /home/vagrant/.ssh/authorized_keys &&
     sudo chown vagrant:vagrant /home/vagrant/.ssh/authorized_keys &&
     sudo chmod 600 /home/vagrant/.ssh/authorized_keys &&
     sudo grep -qxF '$PUBKEY' /home/vagrant/.ssh/authorized_keys ||
     true"

  # Idempotently add the key if it is not present.
  vagrant ssh "$vm" -c \
    "sudo grep -qxF '$PUBKEY' /home/vagrant/.ssh/authorized_keys ||
     echo '$PUBKEY' | sudo tee -a /home/vagrant/.ssh/authorized_keys >/dev/null"
done

echo "Installing verified SSH host keys..."

# Get the real host public key through Vagrant's trusted access,
# rather than blindly trusting ssh-keyscan.
for vm in fetcher postgres ui; do
  case "$vm" in
    fetcher) ip="192.168.56.11" ;;
    postgres) ip="192.168.56.13" ;;
    ui) ip="192.168.56.14" ;;
  esac

  hostkey="$(
    vagrant ssh "$vm" -c \
      "sudo cat /etc/ssh/ssh_host_ed25519_key.pub" |
      tr -d '\r' | grep '^ssh-ed25519 ' | tail -n 1
  )"

  if [[ -z "$hostkey" ]]; then
    echo "ERROR: Could not retrieve host key from $vm"
    exit 1
  fi

  vagrant ssh history -c \
    "sudo touch /root/.ssh/known_hosts &&
     sudo chmod 600 /root/.ssh/known_hosts &&
     sudo grep -qF '$ip ' /root/.ssh/known_hosts ||
     true"

  # Replace only the entry for this IP with the key obtained via Vagrant.
  vagrant ssh history -c \
    "sudo ssh-keygen -R '$ip' -f /root/.ssh/known_hosts >/dev/null 2>&1 || true"

  printf '%s %s\n' "$ip" "$hostkey" |
    vagrant ssh history -c \
      "sudo tee -a /root/.ssh/known_hosts >/dev/null"
done

echo "Copying logging files to History..."

cat "$LOGGING/service-logs.conf" |
  vagrant ssh history -c \
    "sudo tee /etc/service-logs.conf >/dev/null"

cat "$LOGGING/collect-service-logs.sh" |
  vagrant ssh history -c \
    "sudo tee /usr/local/bin/collect-service-logs.sh >/dev/null"

vagrant ssh history -c \
  "sudo chmod 600 /etc/service-logs.conf &&
   sudo chown root:root /etc/service-logs.conf &&
   sudo chmod 750 /usr/local/bin/collect-service-logs.sh &&
   sudo chown root:root /usr/local/bin/collect-service-logs.sh &&
   sudo install -d -m 750 /var/log/services &&
   sudo apt-get update &&
   sudo apt-get install -y cron util-linux logrotate &&
   sudo systemctl enable --now cron"

echo "Configuring cron..."

cat <<'CRON' | vagrant ssh history -c \
  "sudo tee /etc/cron.d/service-log-collector >/dev/null"
*/15 * * * * root /usr/local/bin/collect-service-logs.sh >> /var/log/collect-service-logs-cron.log 2>&1
CRON

vagrant ssh history -c \
  "sudo chmod 644 /etc/cron.d/service-log-collector"

echo "Configuring logrotate..."

cat <<'ROTATE' | vagrant ssh history -c \
  "sudo tee /etc/logrotate.d/service-logs >/dev/null"
/var/log/services/*.log
/var/log/collect-service-logs-cron.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    copytruncate
    su root root
}
ROTATE

vagrant ssh history -c \
  "sudo chmod 644 /etc/logrotate.d/service-logs &&
   sudo logrotate -d /etc/logrotate.d/service-logs"

echo "Testing SSH access..."

for ip in 192.168.56.11 192.168.56.13 192.168.56.14; do
  vagrant ssh history -c \
    "sudo ssh -i /root/.ssh/history_log_collector \
      -o IdentitiesOnly=yes \
      -o BatchMode=yes \
      -o StrictHostKeyChecking=yes \
      -o UserKnownHostsFile=/root/.ssh/known_hosts \
      vagrant@$ip hostname"
done

echo "Running initial log collection..."

vagrant ssh history -c \
  "sudo /usr/local/bin/collect-service-logs.sh"

echo "Logging setup finished."
