# Tube

SSH client for iPhone and iPad, with a browser client and optional
self-hosted, end-to-end encrypted sync. No account, no subscription, no
vendor server.

- iOS: native SwiftUI/UIKit app on SwiftTerm and Citadel (swift-nio-ssh).
  Terminal key bar above the system keyboard, and a full key panel that
  replaces it (esc/tab/ctrl/alt with one-shot and locked modifiers, ^C ^D ^L
  ^Z and other control keys, arrows, home/end/pgup/pgdn, F1-F12, symbols),
  plus snippets, history and theme tabs. Hardware keyboards: Ctrl/Option go to
  the shell, Command is for app shortcuts.
- Hosts with groups, tags, favorites, search and recents; jump host chains
  (ProxyJump) set up by picking hosts in order; ssh_config import/export;
  strict known-hosts checking that never accepts a changed key.
- Identities: Ed25519 generation, OpenSSH key import (Ed25519, RSA) with
  passphrases, stored in the Keychain.
- Web: React + xterm.js PWA. SSH runs in the browser (Go x/crypto/ssh as
  WebAssembly); a small relay gives it a TCP socket. See docs/security.md.
- Sync: `docker compose up -d`. Records are encrypted on the device with
  AES-256-GCM; the server stores ciphertext. Pairing codes, recovery key,
  device revocation with key rotation.

Status per feature: ROADMAP.md. TestFlight setup: docs/release.md.

## Self-hosting

```sh
cp .env.example .env     # domain, registration token, gateway token/allow-list
docker compose up -d
```

This starts the sync server, the SSH relay and the web client behind Caddy
(automatic TLS for `TUBE_DOMAIN`). iOS only needs the sync service.

Create a relay token:

```sh
docker compose run --rm gateway tube-gateway token alice
```

## Development

Linux is enough for everything except compiling the iOS app, which runs on a
GitHub macOS runner (`gh workflow run ios-build.yml`).

```sh
swift test --filter 'TermInputTests|TubeCoreTests'
test/sshd/up.sh && TUBE_SSH_TESTS=1 swift test --filter TubeSSHTests
test/sync.sh          # Swift + web sync clients against the Rust server
test/interop.sh       # records written by web are read by Swift and back
test/web-ssh.sh       # browser SSH module through the relay to test sshd
cd server && cargo test
cd web && npm install && npm run wasm && npm run dev
```

Layout and conventions: CLAUDE.md.

## License

MIT (to be added with the first public release).
