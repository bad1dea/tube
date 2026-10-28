# Roadmap

Status as of 2026-10-28. "Tested" means automated tests run on Linux or in
CI; "compiles" means the iOS target builds on the macOS runner but has not
been run on a device or simulator.

## M0 Environment — done

Existing project `~/ios` (PrivateGallery) on amy builds on GitHub Actions
`macos-26` with XcodeGen and fastlane, manual signing from repo secrets,
upload to TestFlight. Conch reuses that pipeline. Dev machines are Fedora
(leela, amy); no local Xcode.

## M1 Scaffold — done

ConchKit Swift package (Linux-testable), iOS app via XcodeGen, Rust server
workspace, React web app, test containers, CI.

## M2 iOS SSH and hosts — compiles, core tested

- [x] SSH connect, password and Ed25519 auth, encrypted keys (tested vs OpenSSH)
- [x] PTY shell, resize (tested)
- [x] Strict known hosts; changed key refused before auth (tested)
- [x] Jump host chains (tested: bastion -> internal-only host)
- [x] Host list: search, groups, tags, favorites, recents, notes, per-host terminal settings
- [x] ssh_config import/export with ProxyJump (tested)
- [x] Multiple sessions, tab strip, reconnect
- [ ] RSA user auth on iOS (Citadel uses ssh-rsa/SHA-1; needs rsa-sha2-512 signer)
- [ ] Run on a real device

## M3 iOS keyboard — compiles, encoding tested

- [x] Accessory bar: sessions strip, grouped scrollable keys
- [x] Key panel replacing the system keyboard: keys, snippets, history, themes tabs
- [x] CTRL/ALT one-shot, double-tap/long-press lock, visible state
- [x] Encoding: C0 controls, ESC-prefixed alt, DECCKM-aware arrows, modified
      CSI keys, home/end/pgup/pgdn, F1-F12 (unit tests + bytes verified on a real PTY)
- [x] Ctrl+C interrupts a remote job; vim enables application cursor mode (tested)
- [x] Hardware keyboards via SwiftTerm (incl. kitty protocol); Command-only app shortcuts
- [x] Pinch to zoom, keyboard-aware layout via keyboardLayoutGuide, iPad split view
- [ ] Manual pass on device with vim, nano, tmux, htop, less, nested ssh
- [ ] UI tests (needs a simulator run in CI)

## M4 Identities and local vault — compiles

- [x] Ed25519 generation (tested: generated key logs in)
- [x] OpenSSH import with passphrase, public key copy/share, export with warning
- [x] Keychain storage (device-only), Face ID / passcode app lock
- [ ] Encrypted backup file export/import (sync covers multi-device today)

## M5 Self-hosted sync — done, tested

- [x] Server: vaults, devices, records with versions/conflicts, tombstones,
      pairing, recovery, revocation, key rotation, rate limits (11 API tests)
- [x] Swift client (5 live tests), web client (2 live tests), web<->Swift interop
- [x] iOS sync UI: create, pair (QR + code), recover, devices, revoke
- [x] docker compose with Caddy TLS
- [ ] QR scanning on iOS (pairing code is pasted for now)

## M6 Web client and gateway — done, tested end to end

- [x] Relay gateway with token auth, allow-list, origin check, limits, audit log (7 tests)
- [x] SSH in the browser via WebAssembly: password, Ed25519, RSA (rsa-sha2), jump hosts,
      host key prompt (7 end-to-end tests through the relay)
- [x] React app: hosts, tabs, identities, snippets, settings, sync; PWA manifest + service worker
- [ ] Browser UI tests (Playwright)

## M7 SFTP, forwarding, snippets — partial

- [x] Snippets with {{variables}} on iOS and web
- [ ] SFTP browser, upload/download
- [ ] Local / remote / dynamic port forwarding and saved tunnels
      (model exists; iOS backgrounding limits apply)

## M8 Polish — not started

## M9 TestFlight — pipeline ready, blocked on Apple setup

Workflows and fastlane lanes are in place. Needs the App ID, App Store
Connect record, provisioning profile and repo secrets listed in
docs/release.md. No build has been uploaded.

## M10 Desktop — not started

The web client already runs in desktop browsers; Tauri would wrap it and
could replace the relay with a native socket.
