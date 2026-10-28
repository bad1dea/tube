#!/bin/sh
# Generates test keys (once) and starts the containers. Keys are test-only and
# git-ignored.
set -e
cd "$(dirname "$0")"
mkdir -p keys
[ -f keys/host_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -C test-host -f keys/host_ed25519
[ -f keys/client_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -C tube-test -f keys/client_ed25519
[ -f keys/client_ed25519_pw ] || ssh-keygen -q -t ed25519 -N 'hunter2' -C tube-test-pw -f keys/client_ed25519_pw
[ -f keys/client_rsa ] || ssh-keygen -q -t rsa -b 3072 -N '' -C tube-test-rsa -f keys/client_rsa
rm -f keys/host_ed25519.pub.authorized
# host_ed25519.pub must not end up in authorized_keys
mkdir -p keys/host && mv -f keys/host_ed25519.pub keys/host/ 2>/dev/null || true
docker compose up -d --build
for p in 2222 2022; do
  for i in $(seq 1 30); do
    ssh-keyscan -p $p 127.0.0.1 >/dev/null 2>&1 && break
    sleep 0.5
  done
done
