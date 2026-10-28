# Conch

SSH client for iOS/iPadOS with self-hosted end-to-end encrypted sync. Web
client and desktop come later (see ROADMAP.md).

## Layout

- `Package.swift`, `Sources/`, `Tests/`: ConchKit, the platform-independent
  Swift code. Builds and tests on Linux.
  - `TermInput`: xterm key encoding, CTRL/ALT latches, key bar/panel layouts.
  - `ConchCore`: models (Host, Identity, Snippet, PortForward), ssh_config
    import/export, known hosts, vault crypto (AES-256-GCM + HKDF-SHA256).
  - `ConchSSH`: Citadel wrapper. Connection chains (jump hosts), host key
    policy, key generation/import, PTY shells.
- `ios/`: the app. `project.yml` is the XcodeGen spec; the .xcodeproj is
  generated in CI and never committed. UIKit for the terminal input views
  (`Terminal/KeyBar.swift`), SwiftUI for everything else.
- `server/sync`: Rust (axum + SQLite) sync server. Only stores ciphertext.
- `test/sshd`: OpenSSH containers (jump, target, inner) for integration tests.
- `docs/`: crypto and protocol specs, App Store notes.

## Build and test

There is no Xcode on the dev machines (Fedora, hosts `leela` and `amy`).
`/mnt/projects` is the same NFS share on both.

```sh
swift test --filter 'TermInputTests|ConchCoreTests'   # unit, any OS
test/sshd/up.sh && CONCH_SSH_TESTS=1 swift test --filter ConchSSHTests
cd server && cargo test
swiftc -parse $(find ios/Sources -name '*.swift')     # syntax only
gh workflow run ios-build.yml --ref main              # real iOS compile (macOS runner)
gh workflow run testflight.yml --ref main             # signed build -> TestFlight
```

`ios-build.yml` is manual / PR-only to save macOS minutes. Use it after any
change under `ios/` before claiming the app compiles.

## Conventions

- Swift 5.9 language mode, iOS 17 minimum. ObservableObject, not @Observable.
- Pinned dependencies: Citadel exactly 0.12.0 (0.12.1 swapped swift-nio-ssh to
  an unvetted fork), SwiftTerm exactly 1.20.0. Bump only after reading the diff.
- Never add a code path that accepts a changed host key. `KnownHosts.trust`
  refuses to overwrite; replacing a key is an explicit remove from Known Hosts.
- Secrets (passwords, private keys, vault key) live in the Keychain as
  `ThisDeviceOnly` items, never in `conch.json`.
- Vault crypto must stay byte-compatible across Swift, web and Rust. Fixed
  vectors are in `Tests/ConchCoreTests/CoreTests.swift`; docs/vault-crypto.md is
  the spec. Change both or neither.
- Keyboard changes need a test in `KeyEncoderTests` and, if bytes on the wire
  change, in `SSHIntegrationTests.testKeyBytesArriveVerbatim`.
- Security-sensitive server changes need a test in `server/sync/tests/api.rs`.
- Commit identity: `khuong <khuong@khuo.ng>`.

## Signing / TestFlight

Same scheme as `~/ios` (PrivateGallery) on amy: GitHub Actions `macos-26`,
XcodeGen, fastlane `beta` lane with manual signing from repo secrets. The repo
needs its own secrets and an App Store profile for `pro.imnot.conch`; see
docs/release.md.
