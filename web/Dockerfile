# Static web client served by Caddy, which also proxies the sync API and the
# SSH relay so everything shares one origin and one certificate.
FROM docker.io/library/golang:1.26 AS wasm
WORKDIR /src
COPY sshwasm/ ./
RUN GOOS=js GOARCH=wasm go build -trimpath -ldflags="-s -w" -o /out/ssh.wasm . \
 && cp "$(go env GOROOT)/lib/wasm/wasm_exec.js" /out/

FROM docker.io/library/node:22-slim AS web
WORKDIR /src
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY . .
COPY --from=wasm /out/ public/
RUN npm run build

FROM docker.io/library/caddy:2
COPY --from=web /src/dist /srv
COPY Caddyfile /etc/caddy/Caddyfile
