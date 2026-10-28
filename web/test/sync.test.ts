// Web sync client against a live server/sync (CONCH_SYNC_URL, see test/sync.sh).
import { test } from "node:test";
import assert from "node:assert/strict";
import { emptyData, newHost, newID, type WebData } from "../src/model.ts";
import * as s from "../src/vault/sync.ts";

const server = process.env.CONCH_SYNC_URL;
const opts = { skip: !server && "set CONCH_SYNC_URL" };

test("pairing, edits, deletes between two browsers", opts, async () => {
  const { creds: a } = await s.createVault(server!, "a");
  const da: WebData = emptyData();
  const h = { ...newHost(), label: "lab", hostname: "10.0.0.5", username: "root", hasPassword: true };
  da.hosts.push(h);
  da.secrets["pw-" + h.id] = { value: "pw1" };
  da.snippets.push({ id: newID(), name: "up", command: "uptime", folder: "", runImmediately: true, updatedAt: Date.now() });
  assert.equal((await s.sync(a, da)).pushed, 3);

  const b = await s.claim(await s.invite(a), "b");
  const db = emptyData();
  await s.sync(b, db);
  assert.equal(db.hosts[0].hostname, "10.0.0.5");
  assert.equal(db.secrets["pw-" + h.id].value, "pw1");
  assert.equal(db.hosts[0].hasPassword, true);

  db.hosts[0].hostname = "10.0.0.6";
  db.hosts[0].updatedAt = Date.now() + 1;
  db.snippets = [];
  await s.sync(b, db);
  await s.sync(a, da);
  assert.equal(da.hosts[0].hostname, "10.0.0.6");
  assert.equal(da.snippets.length, 0);
  // Nothing left to push after a clean round trip.
  assert.equal((await s.sync(a, da)).pushed, 0);
});

test("revoke rotates key; later recovery sees new data", opts, async () => {
  const { creds: a, recoveryKey } = await s.createVault(server!, "a");
  const lost = await s.recover(server!, a.vaultID, recoveryKey, "lost");
  const da = emptyData();
  da.hosts.push({ ...newHost(), hostname: "h", username: "u" });
  await s.sync(a, da);
  const rotated = await s.revokeAndRotate(a, lost.deviceID, da);
  assert.equal(rotated.epoch, 2);
  await assert.rejects(s.sync(lost, emptyData()), (e: unknown) => e instanceof s.SyncError && e.status === 401);
  const fresh = await s.recover(server!, a.vaultID, recoveryKey.toLowerCase(), "fresh");
  const df = emptyData();
  await s.sync(fresh, df);
  assert.equal(df.hosts[0].hostname, "h");
});
