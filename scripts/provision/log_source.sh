#!/bin/bash
set -euo pipefail

USER_NAME=logreader
HOME_DIR=/home/$USER_NAME

id "$USER_NAME" >/dev/null 2>&1 \
  || useradd --system --create-home --home-dir "$HOME_DIR" --shell /bin/sh "$USER_NAME"

cat > /usr/local/bin/iss-logs <<'EOF'
#!/bin/bash
set -euo pipefail
ts='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
read -r since until extra <<< "${1:-}"
if [[ ! ${since:-} =~ $ts || ! ${until:-} =~ $ts || -n ${extra:-} ]]; then
  echo "usage: <since> <until>  (UTC, e.g. 2026-01-01T00:00:00Z)" >&2
  exit 2
fi
if [[ -f /opt/iss/compose.yaml ]]; then
  cd /opt/iss
  exec docker compose logs --no-color --timestamps --since "$since" --until "$until"
fi
since=${since%Z} until=${until%Z}
exec journalctl --quiet --no-pager --output short-iso-precise --unit ssh --unit fail2ban \
  --since "${since/T/ } UTC" --until "${until/T/ } UTC"
EOF
chown root:root /usr/local/bin/iss-logs
chmod 755 /usr/local/bin/iss-logs

SUDOERS_TMP=$(mktemp)
printf '%s ALL=(root) NOPASSWD: /usr/local/bin/iss-logs\n' "$USER_NAME" > "$SUDOERS_TMP"
visudo -cf "$SUDOERS_TMP" >/dev/null
install -m 440 -o root -g root "$SUDOERS_TMP" /etc/sudoers.d/iss-logreader
rm -f "$SUDOERS_TMP"

install -d -m 700 -o "$USER_NAME" -g "$USER_NAME" "$HOME_DIR/.ssh"
printf 'restrict,from="%s",command="sudo -n /usr/local/bin/iss-logs \\"$SSH_ORIGINAL_COMMAND\\"" %s\n' \
  "$LOG_COLLECTOR_IP" "$LOG_COLLECTOR_PUBKEY" > "$HOME_DIR/.ssh/authorized_keys"
chown "$USER_NAME:$USER_NAME" "$HOME_DIR/.ssh/authorized_keys"
chmod 600 "$HOME_DIR/.ssh/authorized_keys"
