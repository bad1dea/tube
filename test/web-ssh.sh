#!/bin/sh
# Runs the browser SSH module under Node against the gateway and test/sshd.
set -e
cd "$(dirname "$0")/.."
test/sshd/up.sh >/dev/null
[ -f web/public/ssh.wasm ] || web/sshwasm/build.sh
(cd server && cargo build -q -p tube-gateway)
token=test-relay-token
hash=$(printf %s "$token" | sha256sum | cut -d' ' -f1)
TUBE_LISTEN=127.0.0.1:18282 TUBE_GATEWAY_TOKENS="tester:$hash" \
  TUBE_GATEWAY_ALLOW="127.0.0.1:2022,127.0.0.1:2222" RUST_LOG=warn \
  server/target/debug/tube-gateway &
pid=$!
trap 'kill $pid' EXIT
sleep 0.5
TUBE_RELAY_URL=ws://127.0.0.1:18282/relay TUBE_RELAY_TOKEN=$token node --test web/test/ssh-wasm.test.mjs
