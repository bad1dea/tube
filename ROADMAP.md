# Roadmap

Status as of 2026-10-29. "Tested" means automated tests run on Linux or in
CI; "compiles" means the iOS target builds on the macOS runner but has not
been run on a device or simulator.

## M0 Environment — done

Existing project `~/ios` (PrivateGallery) on amy builds on GitHub Actions
`macos-26` with XcodeGen and fastlane, manual signing from repo secrets,
upload to TestFlight. Tube reuses that pipeline. Dev machines are Fedora
(leela, amy); no local Xcode.

## M1 Scaffold — done

TubeKit Swift package (Linux-testable), iOS app via XcodeGen, Rust server
workspace, React web app, test containers, CI.

## M2 iOS SSH and hosts — compiles, core tested

- [x] SSH connect, password and Ed25519 auth, encrypted keys (tested vs OpenSSH)
- [x] PTY shell, resize (tested)
- [x] Strict known hosts; changed key refused before auth (tested)
- [x] Jump host chains (tested: bastion -> internal-only host)
- [x] Host list: search, groups, tags, favorites, recents, notes, per-host terminal settings
- [x] ssh_config import/export with ProxyJump (tested)
- [x] Multiple sessions, tab strip, reconnect
- [x] RSA user auth: rsa-sha2-512, then rsa-sha2-256, then ssh-rsa (tested vs OpenSSH)
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

## M7 SFTP, forwarding, snippets — iOS compiles, protocol layer tested

- [x] Snippets with {{variables}} on iOS and web
- [x] SFTP: list, download, upload (300 KB round trip), mkdir, rename, delete (tested);
      iOS file browser with Quick Look, uploads from Files
- [x] Local (-L), remote (-R), dynamic SOCKS5 (-D) forwarding (tested end to end);
      iOS saved tunnels with on/off toggles
- [ ] Forwards survive backgrounding: not possible on iOS without a VPN
      extension; the app shows them as stopped when it returns
- [ ] SFTP and forwarding in the web client (relay would need one socket per channel)

## M8 Polish — in progress

From the first TestFlight build (0.1 build 3) on a real iPhone:

- [x] Crash on the panel {} tab (unowned controller captured by the panel)
- [x] Key rows could not be swiped (UIScrollView will not cancel UIControl touches)
- [x] Password key typed without asking: now confirms, warns off-prompt, needs Face ID/passcode
- [x] Long-press pad: arrows / scroll, copy, paste, select all
- [x] Host list: quick connect, open sessions, recent, OS tiles, error badge, Library with counts
- [x] Command suggestions while typing (own history + common commands); never records unechoed input
- [x] Background: background task, opt-in location keep-alive, reconnect on return
- [x] Live Activity on the lock screen / Dynamic Island with open sessions
- [x] Simulator UI test that walks these flows and exports screenshots (ios-build.yml)
- [x] RSA user keys on iOS (rsa-sha2 signer)
- [ ] mosh-style roaming / session resume

## M9 TestFlight — done

`testflight.yml` builds, signs and uploads to App Store Connect (first
uploads 2026-10-28/29). Secrets and profile setup are in docs/release.md.

## M10 Desktop — not started

The web client already runs in desktop browsers; Tauri would wrap it and
could replace the relay with a native socket.
