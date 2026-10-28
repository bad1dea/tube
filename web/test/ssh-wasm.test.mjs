// End-to-end: Go SSH (wasm) -> conch-gateway relay -> test/sshd containers.
// Run with test/web-ssh.sh, which starts the gateway and sets env vars.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const here = path.dirname(fileURLToPath(import.meta.url));
const pub = path.join(here, "..", "public");
const keys = path.join(here, "..", "..", "test", "sshd", "keys");
const relayURL = process.env.CONCH_RELAY_URL;
const token = process.env.CONCH_RELAY_TOKEN;

await new Promise((resolve) => {
  globalThis.conchSSHReady = resolve;
  eval(readFileSync(path.join(pub, "wasm_exec.js"), "utf8"));
  const go = new globalThis.Go();
  WebAssembly.instantiate(readFileSync(path.join(pub, "ssh.wasm")), go.importObject).then((r) => go.run(r.instance));
});
const ssh = globalThis.conchSSH;

function session(hops, { accept = true, seen = [] } = {}) {
  let out = "";
  let closed = null;
  const p = ssh.connect({
    relayURL, token, hops, cols: 80, rows: 24,
    onData: (b) => { out += Buffer.from(b).toString("utf8"); },
    onClose: (r) => { closed = r; },
    verifyHostKey: async (host, port, alg, key, fp) => { seen.push({ host, port, alg, fp }); return accept; },
  });
  return {
    p,
    get out() { return out; },
    get closed() { return closed; },
    async waitFor(s, ms = 8000) {
      const end = Date.now() + ms;
      while (Date.now() < end) { if (out.includes(s)) return; await new Promise((r) => setTimeout(r, 50)); }
      throw new Error(`timeout waiting for ${JSON.stringify(s)}; got ${JSON.stringify(out.slice(-300))}`);
    },
  };
}

const target = (extra) => ({ host: "127.0.0.1", port: 2022, user: "tester", ...extra });

test("password login, shell output, resize", async () => {
  const seen = [];
  const s = session([target({ password: "tester-pass" })], { seen });
  const h = await s.p;
  h.write("stty size; echo READY-$((40+2))\r");
  await s.waitFor("READY-42");
  assert.match(s.out, /24 80/);
  h.resize(120, 40);
  h.write("stty size\r");
  await s.waitFor("40 120");
  assert.equal(seen.length, 1);
  assert.match(seen[0].fp, /^SHA256:/);
  h.close();
});

test("ed25519 and passphrase keys", async () => {
  for (const [file, passphrase] of [["client_ed25519", ""], ["client_ed25519_pw", "hunter2"]]) {
    const s = session([target({ privateKey: readFileSync(path.join(keys, file), "utf8"), passphrase })]);
    const h = await s.p;
    h.write("echo KEY-OK\r");
    await s.waitFor("KEY-OK");
    h.close();
  }
});

test("rsa key uses rsa-sha2 and works against modern OpenSSH", async () => {
  const s = session([target({ privateKey: readFileSync(path.join(keys, "client_rsa"), "utf8") })]);
  const h = await s.p;
  h.write("echo RSA-OK\r");
  await s.waitFor("RSA-OK");
  h.close();
});

test("jump host to a server only reachable from the bastion", async () => {
  const seen = [];
  const k = readFileSync(path.join(keys, "client_ed25519"), "utf8");
  const s = session([
    { host: "127.0.0.1", port: 2222, user: "tester", privateKey: k },
    { host: "inner", port: 22, user: "tester", password: "tester-pass" },
  ], { seen });
  const h = await s.p;
  h.write("cat /etc/hostname; echo JUMP-OK\r");
  await s.waitFor("JUMP-OK");
  assert.deepEqual(seen.map((x) => `${x.host}:${x.port}`), ["127.0.0.1:2222", "inner:22"]);
  h.close();
});

test("rejected host key aborts before login", async () => {
  const s = session([target({ password: "tester-pass" })], { accept: false });
  await assert.rejects(s.p, /not accepted/);
});

test("gateway refuses destinations outside its policy", async () => {
  const s = session([{ host: "127.0.0.1", port: 22, user: "x", password: "x" }]);
  await assert.rejects(s.p, /not allowed/);
});

test("key generation produces a usable OpenSSH key", () => {
  const k = ssh.generateKey("web-test");
  assert.match(k.privateKey, /BEGIN OPENSSH PRIVATE KEY/);
  assert.match(k.publicKey, /^ssh-ed25519 \S+ web-test$/);
  assert.equal(ssh.publicKey(k.privateKey), k.publicKey.replace(/ web-test$/, ""));
});
