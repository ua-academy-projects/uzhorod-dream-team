#!/bin/bash
set -euo pipefail

RULES_JSON="$1"
PRIVATE_INTERFACE="eth1"

mkdir -p /etc/project
echo "$RULES_JSON" > /etc/project/firewall-rules.json

if ! command -v jq >/dev/null 2>&1; then
    apt-get update
    apt-get install -y jq
fi

function setup_ufw() {
    ufw --force reset

    ufw default deny incoming
    ufw default allow outgoing

    while IFS= read -r rule; do
        source_ip=$(jq -r '.from.host' <<< "$rule")
        interface=$(jq -r '.interface // empty' <<< "$rule")

        while IFS= read -r port; do
            if [[ -n "$interface" ]]; then
                ufw allow in on "$interface" from "$source_ip" to any port "$port" proto tcp
            elif [[ "$source_ip" == "*" ]]; then
                ufw allow "$port/tcp"
            else
                ufw allow from "$source_ip" to any port "$port" proto tcp
            fi
        done < <(jq -r '.from.ports[]' <<< "$rule")
    done < <(jq -c '.[]' <<< "$RULES_JSON")

    ufw --force enable
}

function setup_systemd_docker_firewall() {
    cat > /usr/local/sbin/project-docker-firewall.sh << 'EOF'
#!/bin/bash
set -euo pipefail
RULES_JSON=$(cat /etc/project/firewall-rules.json)
PRIVATE_INTERFACE="eth1"

for i in {1..30; do
    iptables -nL DOCKER-USER >/dev/null 2>&1 && break
    sleep 1
done

if ! iptables -nL DOCKER-USER >/dev/null 2>&1; then
    echo "ERROR: DOCKER-USER chain not found" >&2
    exit 1
fi

iptables -N PROJECT-DOCKER 2>/dev/null || true

iptables -C DOCKER-USER -j PROJECT-DOCKER 2>/dev/null ||
    iptables -I DOCKER-USER 1 -j PROJECT-DOCKER

iptables -F PROJECT-DOCKER

iptables -A PROJECT-DOCKER \
    -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

while IFS= read -r rule; do
    source_ip=$(jq -r '.from.host' <<< "$rule")

    while IFS= read -r port; do
        if [[ "$source_ip" == "*" ]]; then
            iptables -A PROJECT-DOCKER \
                -p tcp \
                -m conntrack --ctorigdstport "$port" \
                -j RETURN
        else
            iptables -A PROJECT-DOCKER \
                -s "$source_ip" \
                -p tcp \
                -m conntrack --ctorigdstport "$port" \
                -j RETURN
        fi
    done < <(jq -r '.from.ports[]' <<< "$rule")
done < <(jq -c '.[] | select(.docker == true)' <<< "$RULES_JSON")

iptables -A PROJECT-DOCKER -i "$PRIVATE_INTERFACE" -j DROP
iptables -A PROJECT-DOCKER -j RETURN
EOF

chmod +x /usr/local/sbin/project-docker-firewall.sh

cat > /etc/systemd/system/project-docker-firewall.service << 'EOF'
[Unit]
Description=Project Docker Firewall Rules
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/project-docker-firewall.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable project-docker-firewall.service
    systemctl restart project-docker-firewall.service
}


setup_ufw
setup_systemd_docker_firewall