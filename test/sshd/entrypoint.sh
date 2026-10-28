#!/bin/sh
# Host key comes from the mounted keys dir so tests can pin it, unless a test
# asks for a fresh one (HOSTKEY=fresh) to simulate a changed server key.
if [ "$HOSTKEY" = fresh ] || [ ! -f /keys/host_ed25519 ]; then
  ssh-keygen -q -t ed25519 -N '' -f /etc/ssh/ssh_host_ed25519_key
else
  cp /keys/host_ed25519 /etc/ssh/ssh_host_ed25519_key
  chmod 600 /etc/ssh/ssh_host_ed25519_key
fi
cat /keys/*.pub > /home/tester/.ssh/authorized_keys 2>/dev/null
chown tester:tester /home/tester/.ssh/authorized_keys
chmod 600 /home/tester/.ssh/authorized_keys
exec /usr/sbin/sshd -D -e
