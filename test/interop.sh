#!/bin/sh
# Web client and Swift client exchange records through one sync server:
# web creates, Swift decodes as ConchCore types and edits, web verifies.
set -e
cd "$(dirname "$0")/.."
(cd server && cargo build -q -p conch-sync)
tmp=$(mktemp -d)
CONCH_DB=$tmp/sync.db CONCH_LISTEN=127.0.0.1:18183 RUST_LOG=warn server/target/debug/conch-sync &
pid=$!
trap 'kill $pid; rm -rf $tmp' EXIT
for i in $(seq 1 50); do curl -sf http://127.0.0.1:18183/healthz >/dev/null && break; sleep 0.1; done
export CONCH_SYNC_URL=http://127.0.0.1:18183 CONCH_INTEROP_FILE=$tmp/interop.json
node --experimental-strip-types --no-warnings web/test/interop.ts create "$CONCH_INTEROP_FILE"
swift test --filter InteropTests 2>&1 | grep -E "error|failed|passed|Executed" | tail -5
node --experimental-strip-types --no-warnings web/test/interop.ts verify "$CONCH_INTEROP_FILE"
