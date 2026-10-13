#!/usr/bin/env bash
# Every VM behind the bastion: ssh only from the bastion (and Vagrant itself),
# enforced twice — by sshd and by the firewall.
set -euo pipefail

: "${BASTION_IP:?BASTION_IP must be provided by the provisioner}"
: "${PRIVATE_NET:?PRIVATE_NET must be provided by the provisioner}"

# The bastion key opens the vagrant account; the bastion itself never sees it.
key=$(cat /tmp/bastion_key.pub)
rm -f /tmp/bastion_key.pub
grep -qxF "$key" /home/vagrant/.ssh/authorized_keys || echo "$key" >> /home/vagrant/.ssh/authorized_keys

cat > /etc/ssh/sshd_config.d/10-bastion-only.conf <<CONF
PasswordAuthentication no
KbdInteractiveAuthentication no
# vagrant: through the bastion or from Vagrant; logs: log shipping inside the private network.
AllowUsers vagrant@${BASTION_IP} vagrant@192.168.121.1 logs@${PRIVATE_NET%.*}.*
CONF
rm -f /etc/ssh/sshd_config.d/50-cloud-init.conf
sshd -t
systemctl reload ssh

# Firewall layer: only our own table, so Docker's rules stay untouched.
install -d /etc/nftables.d
cat > /etc/nftables.d/ssh-guard.nft <<NFT
table inet ssh_guard
delete table inet ssh_guard
table inet ssh_guard {
  chain input {
    type filter hook input priority 0; policy accept;
    # .1 is the host's own address in the private network: no shortcut around the bastion.
    tcp dport 22 ip saddr ${PRIVATE_NET%.*/*}.1 drop
    tcp dport 22 ip saddr { ${PRIVATE_NET}, 192.168.121.1 } accept
    tcp dport 22 drop
  }
}
NFT
nft -f /etc/nftables.d/ssh-guard.nft
# At boot nftables.service loads it; no "flush ruleset", it runs before Docker anyway.
printf '#!/usr/sbin/nft -f\ninclude "/etc/nftables.d/*.nft"\n' > /etc/nftables.conf
systemctl enable nftables >/dev/null 2>&1