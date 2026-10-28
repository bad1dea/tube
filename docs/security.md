# Trust boundaries

## iOS app

Talks SSH directly to your servers. Secrets live in the Keychain as
`AfterFirstUnlockThisDeviceOnly` items: not in iCloud Keychain, not in
backups that restore to another device. Private keys are ordinary Keychain
items, not Secure Enclave keys: the Secure Enclave only holds P-256 keys it
generates itself and cannot store or use imported Ed25519/RSA SSH keys.

Optional app lock (Face ID / passcode) hides the UI; it does not add a second
encryption layer.

## Host keys

First connection shows the SHA-256 fingerprint and asks. A key that differs
from the stored one fails the connection before authentication; there is no
"accept anyway" button. To replace a key, delete it under Known hosts, then
connect and confirm again. Each hop of a jump chain is checked under its own
`host:port`. Keys received by sync are added only for endpoints with no
stored key.

## Sync server

Sees: vault id, device names and last-seen times, record ids and kinds,
ciphertext sizes, request times and client IPs. Cannot see host names,
users, passwords, keys, snippets or settings. Crypto details:
docs/vault-crypto.md. A malicious server can withhold or roll back records
(availability), but cannot read or forge them: records are AES-GCM with the
record id and kind in the AAD.

## Web client and relay

Browsers cannot open TCP sockets. The web client runs the SSH protocol
itself in WebAssembly (golang.org/x/crypto/ssh) and sends the SSH byte
stream over a WebSocket to `tube-gateway`, which opens the TCP connection.

The gateway **does not** terminate SSH. It sees the destination host and
port, connection times and byte counts, and the client IP. It never receives
passwords, private keys or terminal contents; those stay inside the page.
Host key verification happens in the page, so a compromised gateway cannot
impersonate a server whose key is already known.

Gateway controls:

- Token per user (first WebSocket frame, not the URL); stored as SHA-256.
- Destination allow-list (`TUBE_GATEWAY_ALLOW`) by CIDR or name and port.
  Resolved addresses are checked, so DNS cannot point an allowed name at
  loopback or 169.254.169.254. Loopback and link-local are refused unless a
  CIDR rule names them.
- `Origin` must match `TUBE_GATEWAY_ORIGINS`.
- Per-user concurrent session cap, per-IP connection rate limit.
- Audit log line per session: user, client IP, destination, duration, bytes.
- Each WebSocket gets its own TCP connection; sessions share nothing.
- TLS from Caddy in the compose setup.

The web page itself is trusted code: whoever serves it can change it to leak
secrets. Serve it yourself, over HTTPS, from the compose setup.

Browser storage: the local vault is AES-GCM encrypted under a PBKDF2-SHA256
(600k iterations) key from a passphrase entered on each load. XSS in the page
would defeat this; the CSP in web/Caddyfile allows only same-origin scripts.

## Things not done yet

- RSA user keys on iOS: Citadel signs with `ssh-rsa` (SHA-1), which
  OpenSSH 8.8+ refuses. Ed25519 works. The web client signs RSA correctly.
- No certificate pinning of the sync server beyond normal TLS validation.
- No independent audit.
