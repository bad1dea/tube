# Vault encryption

Implemented in `Sources/TubeCore/VaultCrypto.swift`. Web and server code must
match it byte for byte; the fixed vector at the end is asserted in Swift tests.

## Keys

| Name | Size | Origin |
|------|------|--------|
| VK, vault key | 32 bytes | random, created with the vault |
| RK, recovery key | 20 bytes | random, shown once to the user as base32 |
| KEK | 32 bytes | HKDF-SHA256(ikm=RK, salt=vaultID, info="tube-kek-v1") |
| recovery auth | 32 bytes | HKDF-SHA256(ikm=RK, salt=vaultID, info="tube-recovery-auth-v1") |
| record key | 32 bytes | HKDF-SHA256(ikm=VK, salt=vaultID, info="tube-record-v1") |
| pairing key | 32 bytes | HKDF-SHA256(ikm=pairing secret, salt=inviteID, info="tube-pair-v1") |

Salts and info strings are UTF-8. HKDF output length is 32.

RK is random and has 160 bits of entropy, so a slow password KDF is not
needed and the wrapped VK stored on the server cannot be brute-forced offline.
The user writes RK down; it is the only way back in if every device is lost.

RK display form: RFC 4648 base32 without padding, 32 characters, split into
groups of four with `-`. Input is case-insensitive and ignores `-` and spaces.

## Sealing

AES-256-GCM, 12-byte random nonce, 16-byte tag. Sealed form is
`nonce || ciphertext || tag`, base64 (standard alphabet, padded) in JSON.

| What | Key | AAD |
|------|-----|-----|
| wrapped VK | KEK | `tube-vk-v1|<vaultID>` |
| record | record key | `tube-record-v1|<vaultID>|<recordID>|<kind>` |
| pairing payload (VK) | pairing key | `tube-pair-v1|<inviteID>` |

The record AAD stops the server from moving a ciphertext to another record id
or presenting a host record as an identity.

## What the server learns

Vault id, device names, record ids, record kinds (`host`, `group`, `identity`,
`secret`, `snippet`, `forward`, `settings`), ciphertext sizes, and timing. Not:
host names, users, keys, passwords, snippet text.

Record ids are random UUIDs, not derived from content.

## Recovery rules

- Lose one device: pair a new one from any remaining device, or use RK.
- Lose all devices: install fresh, choose "Recover", enter vault id + RK. The
  server hands over the wrapped VK only after the recovery auth matches its
  stored SHA-256.
- Lose RK but keep a device: open Sync settings on that device and create a
  new RK (re-wraps VK; server copy is replaced).
- Lose RK and all devices: the data is gone. The server cannot help.

## Revocation

Revoking a device stops its token immediately and deletes its pending invites.
It already knows VK, so revocation is followed by a key rotation: a remaining
device creates VK', re-encrypts every record at epoch+1, uploads them, then
`PUT /v1/vault/key` with the new wrapped key and epoch. Pushes at the old epoch
are rejected from then on.

## Test vector

```
RK  = 00 01 02 ... 13            (bytes 0..19)
VK  = 64 65 66 ... 83            (bytes 100..131)
vaultID = "vault-test"

RK display     AAAQ-EAYE-AUDA-OCAJ-BIFQ-YDIO-B4IB-CEQT
recovery auth  PI0075RFvxEL4uVbeFlTSsKnTd+UL6onZdftX9G8Mpo=
record key     w7dOgz2l/n1IJS5godqscl1jgBK8TV66jJdU+SQfus4=
```

Checked against an independent Python HMAC implementation of HKDF.
