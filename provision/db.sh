#!/usr/bin/env bash
source /vagrant/provision/common.sh
base_setup
: "${POSTGRES_PASSWORD:?}" "${REDIS_PASSWORD:?}" "${RABBITMQ_PASSWORD:?}" "${DB_IP:?}" "${HISTORY_IP:?}"
: "${POSTGRES_PORT:?}" "${REDIS_PORT:?}" "${RABBITMQ_PORT:?}" "${RABBITMQ_UI_PORT:?}"

apt-get install -y -qq postgresql redis-server rabbitmq-server
PGCONF=$(ls -d /etc/postgresql/*/main)

sed -i "s/^#\?listen_addresses.*/listen_addresses = '$DB_IP'/" "$PGCONF/postgresql.conf"
sed -i "s/^#\?port = .*/port = $POSTGRES_PORT/" "$PGCONF/postgresql.conf"
sed -i '/# weather-managed/d' "$PGCONF/pg_hba.conf"
echo "host all postgres $HISTORY_IP/32 scram-sha-256 # weather-managed" >> "$PGCONF/pg_hba.conf"

systemctl enable postgresql
systemctl restart postgresql

sudo --preserve-env=POSTGRES_PASSWORD -u postgres psql -v ON_ERROR_STOP=1 <<'SQL'
\set pw `printenv POSTGRES_PASSWORD`
ALTER USER postgres PASSWORD :'pw';
SQL
sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${POSTGRES_DB:-weather}'" | grep -q 1 \
  || sudo -u postgres createdb "${POSTGRES_DB:-weather}"

install -m 0640 -o root -g redis /dev/stdin /etc/redis/weather.conf <<CONF
bind $DB_IP
port $REDIS_PORT
protected-mode yes
requirepass $REDIS_PASSWORD
appendonly yes
maxmemory 64mb
maxmemory-policy volatile-lru
CONF
sed -i '\|^include /etc/redis/weather.conf$|d' /etc/redis/redis.conf
echo "include /etc/redis/weather.conf" >> /etc/redis/redis.conf

systemctl enable redis-server
systemctl restart redis-server

install -m 0644 /dev/stdin /etc/rabbitmq/rabbitmq.conf <<CONF
listeners.tcp.default = $DB_IP:$RABBITMQ_PORT
management.tcp.ip = $DB_IP
management.tcp.port = $RABBITMQ_UI_PORT
loopback_users.guest = true
CONF
install -m 0640 -o root -g rabbitmq /dev/stdin /etc/rabbitmq/advanced.config <<CONF
[{rabbitmq_tracing, [{username, <<"weather">>}, {password, <<"$RABBITMQ_PASSWORD">>}]}].
CONF
rabbitmq-plugins enable --offline rabbitmq_management rabbitmq_tracing
systemctl enable rabbitmq-server
systemctl restart rabbitmq-server
rabbitmqctl await_startup

rabbitmqctl --silent list_vhosts | grep -qx weather || rabbitmqctl add_vhost weather
rabbitmqctl --silent list_users | grep -q '^weather[[:space:]]' || rabbitmqctl add_user weather "$RABBITMQ_PASSWORD"
rabbitmqctl change_password weather "$RABBITMQ_PASSWORD"
rabbitmqctl set_user_tags weather administrator
rabbitmqctl set_permissions -p weather weather '.*' '.*' '.*'
if rabbitmqctl --silent list_users | grep -q '^guest[[:space:]]'; then rabbitmqctl delete_user guest; fi
