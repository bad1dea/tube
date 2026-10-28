#!/bin/sh
# Starts server/sync on a temporary database and runs the Swift sync tests
# against it.
set -e
cd "$(dirname "$0")/.."
(cd server && cargo build -q -p tube-sync)
db=$(mktemp -d)/sync.db
TUBE_DB=$db TUBE_LISTEN=127.0.0.1:18181 RUST_LOG=warn server/target/debug/tube-sync &
pid=$!
trap 'kill $pid' EXIT
for i in $(seq 1 50); do curl -sf http://127.0.0.1:18181/healthz >/dev/null && break; sleep 0.1; done
TUBE_SYNC_URL=http://127.0.0.1:18181 swift test --filter SyncTests "$@"
(cd web && TUBE_SYNC_URL=http://127.0.0.1:18181 node --experimental-strip-types --no-warnings --test test/sync.test.ts)
