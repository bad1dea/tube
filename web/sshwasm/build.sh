#!/bin/sh
# Builds ssh.wasm and copies Go's wasm_exec.js into web/public. Uses the Go
# container so no local Go toolchain is needed.
set -e
cd "$(dirname "$0")"
docker run --rm -v "$PWD/..":/web:z -w /web/sshwasm -e GOOS=js -e GOARCH=wasm -e GOFLAGS=-buildvcs=false \
  docker.io/library/golang:1.26 sh -c '
    [ -f go.sum ] || { go mod init conch/sshwasm 2>/dev/null; go get golang.org/x/crypto@v0.58.0; }
    go mod tidy
    go build -trimpath -ldflags="-s -w" -o /web/public/ssh.wasm .
    cp "$(go env GOROOT)/lib/wasm/wasm_exec.js" /web/public/wasm_exec.js'
ls -la ../public/ssh.wasm
