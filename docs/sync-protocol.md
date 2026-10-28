# Sync protocol (v1)

Server: `server/sync`. JSON over HTTPS. Device requests carry
`Authorization: Bearer <device token>`. Tokens are `<deviceID>.<secret>`; the
server keeps SHA-256 of the whole token.

## Endpoints

| Method | Path | Auth | Notes |
|--------|------|------|-------|
| POST | /v1/vaults | registration token if configured | create vault, first device |
| GET | /v1/vault | device | wrapped VK and key epoch |
| PUT | /v1/vault/key | device | rotate; `key_epoch` must be current + 1 |
| GET | /v1/records?since=N | device | records with seq > N, 1000 per page |
| POST | /v1/records | device | push batch (max 500) |
| GET | /v1/devices | device | list |
| DELETE | /v1/devices/{id} | device | revoke |
| POST | /v1/pairing | device | store pairing payload, 10 min TTL |
| POST | /v1/pairing/{invite}/claim | none (invite id is the capability) | single use |
| POST | /v1/recover | none, recovery auth | enrol a device with RK |
| GET | /healthz | none | |

Unauthenticated POSTs are rate limited (10 per minute per client address and
route; recovery also 10 per minute per vault).

## Records

```json
{"id": "uuid", "kind": "host", "version": 3, "epoch": 1, "deleted": false,
 "ciphertext": "base64", "seq": 41, "updated_by": "deviceID", "updated_at": 1730000000}
```

`version` is per record, `seq` is per vault and increases on every write.
Clients keep the highest `seq` they have applied as their cursor.

Push: each record names `base_version`, the version the client last saw (0 for
new). If the server's version differs, the record is not written and the
server copy is returned under `conflicts`. The client decrypts both and
resolves (hosts/snippets: newest `updatedAt` inside the plaintext wins and the
loser is kept as a copy; secrets: newest wins), then pushes again with the
server version as base.

Deletes are tombstones (`deleted: true`, no ciphertext) so offline devices
learn about them.

## Pairing

1. Existing device picks a random 16-byte invite id and a random 32-byte
   secret, seals VK under the pairing key (docs/vault-crypto.md), and POSTs the
   payload.
2. It shows `conch-pair:<server>/<inviteID>/<secret base64url>` as a QR code
   and text.
3. New device claims the invite, receives a token and the payload, derives the
   pairing key from the secret, and opens VK.

The server never receives the secret.

## Deployment

`docker compose up -d` at the repo root runs the server behind Caddy with
automatic TLS. Set `CONCH_REGISTRATION_TOKEN` on anything reachable from the
internet. Data is one SQLite file in the `sync-data` volume; back it up with
`sqlite3 conch-sync.db ".backup out.db"` or by copying it while stopped.
