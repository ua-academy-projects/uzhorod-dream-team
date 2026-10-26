#!/bin/bash
sed -i 's/MaxSessions 0/MaxSessions 1/' /etc/ssh/kyiv-air-bastion-public.conf
/usr/sbin/sshd -t && systemctl reload ssh
