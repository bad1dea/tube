import { test } from "node:test";
import assert from "node:assert/strict";
import {
  b64, base32, open, parseRecoveryKey, recordAAD, recordKey, recoveryAuth, recoveryKeyDisplay, seal, unbase32,
  kek, vkAAD,
} from "../src/vault/crypto.ts";

const range = (a: number, b: number) => Uint8Array.from({ length: b - a }, (_, i) => a + i);

test("matches the Swift test vector", async () => {
  const rk = range(0, 20);
  const vk = range(100, 132);
  assert.equal(recoveryKeyDisplay(rk), "AAAQ-EAYE-AUDA-OCAJ-BIFQ-YDIO-B4IB-CEQT");
  assert.equal(b64(await recoveryAuth(rk, "vault-test")), "yS2CxAdPAZj3DkxzyheNaVhfmlx39gk0GS57tPq+aNY=");
  assert.equal(b64(await recordKey(vk, "vault-test")), "IYxuB5g+yb1iZ2mLpVoiu6A04J/v8DEFg9d/J7B2X5Q=");
});

test("base32 round trip and recovery key parsing", () => {
  for (let n = 0; n < 40; n++) {
    const b = range(0, n).map((x) => (x * 37) & 0xff);
    assert.deepEqual(unbase32(base32(b)), b);
  }
  const rk = range(0, 20);
  assert.deepEqual(parseRecoveryKey(recoveryKeyDisplay(rk).toLowerCase().replace(/-/g, " ")), rk);
  assert.throws(() => parseRecoveryKey("ABCD"));
});

test("seal binds AAD", async () => {
  const key = range(1, 33);
  const s = await seal(new TextEncoder().encode("{}"), key, recordAAD("v", "a", "host"));
  assert.deepEqual(new TextDecoder().decode(await open(s, key, recordAAD("v", "a", "host"))), "{}");
  await assert.rejects(open(s, key, recordAAD("v", "b", "host")));
  await assert.rejects(open(s, key, recordAAD("v", "a", "identity")));
});

test("wrapped vault key format matches Swift wrap()", async () => {
  // Swift: seal(VK, key: KEK(RK, vaultID), aad: "conch-vk-v1|<vaultID>")
  const rk = range(0, 20);
  const vk = range(100, 132);
  const k = await kek(rk, "vault-test");
  const wrapped = await seal(vk, k, vkAAD("vault-test"));
  assert.equal(wrapped.length, 12 + 32 + 16);
  assert.deepEqual(await open(wrapped, k, vkAAD("vault-test")), vk);
});
