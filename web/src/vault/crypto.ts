// WebCrypto port of Sources/ConchCore/VaultCrypto.swift. Spec and test vector:
// docs/vault-crypto.md. Keep byte-compatible with the Swift and server side.

const enc = new TextEncoder();
const subtle = globalThis.crypto.subtle;

export function randomBytes(n: number): Uint8Array {
  const b = new Uint8Array(n);
  globalThis.crypto.getRandomValues(b);
  return b;
}

export function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) {
    out.set(p, o);
    o += p.length;
  }
  return out;
}

export function b64(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s);
}

export function unb64(s: string): Uint8Array {
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export function b64url(bytes: Uint8Array): string {
  return b64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function unb64url(s: string): Uint8Array {
  let t = s.replace(/-/g, "+").replace(/_/g, "/");
  while (t.length % 4) t += "=";
  return unb64(t);
}

const B32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

export function base32(bytes: Uint8Array): string {
  let out = "";
  let buffer = 0;
  let bits = 0;
  for (const byte of bytes) {
    buffer = (buffer << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      out += B32[(buffer >> (bits - 5)) & 31];
      bits -= 5;
    }
    buffer &= (1 << bits) - 1;
  }
  if (bits > 0) out += B32[(buffer << (5 - bits)) & 31];
  return out;
}

export function unbase32(s: string): Uint8Array | null {
  const out: number[] = [];
  let buffer = 0;
  let bits = 0;
  for (const c of s) {
    const v = B32.indexOf(c);
    if (v < 0) return null;
    buffer = ((buffer << 5) | v) & 0xffff;
    bits += 5;
    if (bits >= 8) {
      out.push((buffer >> (bits - 8)) & 0xff);
      bits -= 8;
    }
  }
  return new Uint8Array(out);
}

export function recoveryKeyDisplay(rk: Uint8Array): string {
  return base32(rk).match(/.{1,4}/g)!.join("-");
}

export function parseRecoveryKey(s: string): Uint8Array {
  const b = unbase32(s.toUpperCase().replace(/[-\s]/g, ""));
  if (!b || b.length !== 20) throw new Error("Recovery key must be 32 base32 characters");
  return b;
}

async function hkdf(ikm: Uint8Array, salt: string, info: string): Promise<Uint8Array> {
  const key = await subtle.importKey("raw", ikm as BufferSource, "HKDF", false, ["deriveBits"]);
  const bits = await subtle.deriveBits(
    { name: "HKDF", hash: "SHA-256", salt: enc.encode(salt), info: enc.encode(info) },
    key,
    256,
  );
  return new Uint8Array(bits);
}

export const kek = (rk: Uint8Array, vaultID: string) => hkdf(rk, vaultID, "conch-kek-v1");
export const recoveryAuth = (rk: Uint8Array, vaultID: string) => hkdf(rk, vaultID, "conch-recovery-auth-v1");
export const recordKey = (vk: Uint8Array, vaultID: string) => hkdf(vk, vaultID, "conch-record-v1");
export const pairingKey = (secret: Uint8Array, inviteID: string) => hkdf(secret, inviteID, "conch-pair-v1");

export async function seal(plain: Uint8Array, key: Uint8Array, aad: string): Promise<Uint8Array> {
  const k = await subtle.importKey("raw", key as BufferSource, "AES-GCM", false, ["encrypt"]);
  const nonce = randomBytes(12);
  const ct = await subtle.encrypt({ name: "AES-GCM", iv: nonce as BufferSource, additionalData: enc.encode(aad) }, k, plain as BufferSource);
  return concat(nonce, new Uint8Array(ct));
}

export async function open(sealed: Uint8Array, key: Uint8Array, aad: string): Promise<Uint8Array> {
  const k = await subtle.importKey("raw", key as BufferSource, "AES-GCM", false, ["decrypt"]);
  const pt = await subtle.decrypt(
    { name: "AES-GCM", iv: sealed.slice(0, 12) as BufferSource, additionalData: enc.encode(aad) },
    k,
    sealed.slice(12) as BufferSource,
  );
  return new Uint8Array(pt);
}

export const vkAAD = (vaultID: string) => `conch-vk-v1|${vaultID}`;
export const recordAAD = (vaultID: string, id: string, kind: string) => `conch-record-v1|${vaultID}|${id}|${kind}`;
export const pairAAD = (inviteID: string) => `conch-pair-v1|${inviteID}`;

/// Local at-rest key for the browser copy of the vault: PBKDF2 over a
/// passphrase the user picks for this browser. Separate from the recovery key.
export async function localKey(passphrase: string, salt: Uint8Array, iterations = 600_000): Promise<Uint8Array> {
  const k = await subtle.importKey("raw", enc.encode(passphrase), "PBKDF2", false, ["deriveBits"]);
  const bits = await subtle.deriveBits({ name: "PBKDF2", hash: "SHA-256", salt: salt as BufferSource, iterations }, k, 256);
  return new Uint8Array(bits);
}
