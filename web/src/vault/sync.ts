// Port of Sources/TubeSync and the iOS AppSyncStore. Protocol: docs/sync-protocol.md.

import type { Host, HostGroup, Identity, KnownHostKey, Secret, Snippet, SyncCredentials, WebData } from "../model.ts";
import {
  b64, b64url, base32, concat, kek as deriveKEK, open, pairAAD, pairingKey, parseRecoveryKey, randomBytes,
  recordAAD, recordKey, recoveryAuth, recoveryKeyDisplay, seal, unb64, unb64url, vkAAD,
} from "./crypto.ts";

export class SyncError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(`Sync server returned ${status}: ${message}`);
    this.status = status;
  }
}

interface ServerRecord {
  id: string; kind: string; version: number; epoch: number; deleted: boolean;
  ciphertext: string | null; seq: number; updated_by: string; updated_at: number;
}

async function api<T>(base: string, method: string, path: string, token?: string, body?: unknown, headers: Record<string, string> = {}): Promise<T> {
  const r = await fetch(new URL(path, base.endsWith("/") ? base : base + "/"), {
    method,
    headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}), ...headers },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (!r.ok) {
    let msg = await r.text();
    try { msg = JSON.parse(msg).error ?? msg; } catch { /* plain text */ }
    throw new SyncError(r.status, msg);
  }
  return r.status === 204 ? (undefined as T) : r.json();
}

const vk = (c: SyncCredentials, epoch: number) => {
  const k = c.keys[epoch];
  if (!k) throw new Error(`No vault key for epoch ${epoch}`);
  return unb64(k);
};

// ---------------------------------------------------------------- lifecycle

export async function createVault(server: string, deviceName: string, registration?: string): Promise<{ creds: SyncCredentials; recoveryKey: string }> {
  const vaultID = crypto.randomUUID();
  const key = randomBytes(32);
  const rk = randomBytes(20);
  const k = await deriveKEK(rk, vaultID);
  const dev = await api<{ device_id: string; token: string }>(server, "POST", "v1/vaults", undefined, {
    vault_id: vaultID, wrapped_key: b64(await seal(key, k, vkAAD(vaultID))),
    recovery_auth: b64(await recoveryAuth(rk, vaultID)), device_name: deviceName,
  }, registration ? { "x-tube-registration": registration } : {});
  return {
    creds: { serverURL: server, vaultID, deviceID: dev.device_id, token: dev.token, epoch: 1, keys: { 1: b64(key) }, kek: b64(k) },
    recoveryKey: recoveryKeyDisplay(rk),
  };
}

export async function recover(server: string, vaultID: string, recoveryKeyText: string, deviceName: string): Promise<SyncCredentials> {
  const rk = parseRecoveryKey(recoveryKeyText);
  const r = await api<{ device: { device_id: string; token: string }; wrapped_key: string; key_epoch: number }>(
    server, "POST", "v1/recover", undefined,
    { vault_id: vaultID, recovery_auth: b64(await recoveryAuth(rk, vaultID)), device_name: deviceName });
  const k = await deriveKEK(rk, vaultID);
  const key = await open(unb64(r.wrapped_key), k, vkAAD(vaultID));
  return { serverURL: server, vaultID, deviceID: r.device.device_id, token: r.device.token, epoch: r.key_epoch, keys: { [r.key_epoch]: b64(key) }, kek: b64(k) };
}

export async function invite(c: SyncCredentials): Promise<string> {
  const inviteID = base32(randomBytes(16));
  const secret = randomBytes(32);
  const payload = await seal(concat(vk(c, c.epoch), unb64(c.kek)), await pairingKey(secret, inviteID), pairAAD(inviteID));
  await api(c.serverURL, "POST", "v1/pairing", c.token, { invite_id: inviteID, payload: b64(payload) });
  const q = new URLSearchParams({ server: c.serverURL, invite: inviteID, secret: b64url(secret) });
  return `tube://pair?${q}`;
}

export async function claim(code: string, deviceName: string): Promise<SyncCredentials> {
  const m = code.trim().match(/^tube:\/\/pair\?(.*)$/);
  if (!m) throw new Error("Not a Tube pairing code");
  const q = new URLSearchParams(m[1]);
  const server = q.get("server"), inviteID = q.get("invite"), secret = q.get("secret");
  if (!server || !inviteID || !secret) throw new Error("Pairing code is incomplete");
  const r = await api<{ device: { vault_id: string; device_id: string; token: string }; payload: string; key_epoch: number }>(
    server, "POST", `v1/pairing/${inviteID}/claim`, undefined, { device_name: deviceName });
  const opened = await open(unb64(r.payload), await pairingKey(unb64url(secret), inviteID), pairAAD(inviteID));
  if (opened.length !== 64) throw new Error("Bad pairing payload");
  return {
    serverURL: server, vaultID: r.device.vault_id, deviceID: r.device.device_id, token: r.device.token,
    epoch: r.key_epoch, keys: { [r.key_epoch]: b64(opened.slice(0, 32)) }, kek: b64(opened.slice(32)),
  };
}

export interface DeviceInfo { id: string; name: string; created_at: number; last_seen: number; revoked: boolean; current: boolean }

export const devices = (c: SyncCredentials) => api<DeviceInfo[]>(c.serverURL, "GET", "v1/devices", c.token);

export async function revokeAndRotate(c: SyncCredentials, deviceID: string, data: WebData): Promise<SyncCredentials> {
  await api(c.serverURL, "DELETE", `v1/devices/${deviceID}`, c.token);
  await sync(c, data);
  const next = randomBytes(32);
  const epoch = c.epoch + 1;
  await api(c.serverURL, "PUT", "v1/vault/key", c.token, { wrapped_key: b64(await seal(next, unb64(c.kek), vkAAD(c.vaultID))), key_epoch: epoch });
  const rotated: SyncCredentials = { ...c, epoch, keys: { ...c.keys, [epoch]: b64(next) } };
  for (const m of Object.values(data.sync.meta)) if (m.serverVersion > 0) m.hash = "rebase";
  await sync(rotated, data);
  return rotated;
}

// ---------------------------------------------------------------- records

type Item = { kind: string; body: string; updatedAt: number };

/// Stable JSON with sorted keys and no undefined fields, so hashes are stable.
function stable(v: unknown): string {
  if (Array.isArray(v)) return `[${v.map(stable).join(",")}]`;
  if (v && typeof v === "object") {
    return `{${Object.keys(v).filter((k) => (v as Record<string, unknown>)[k] !== undefined).sort()
      .map((k) => `${JSON.stringify(k)}:${stable((v as Record<string, unknown>)[k])}`).join(",")}}`;
  }
  return JSON.stringify(v);
}

async function sha256hex(s: string): Promise<string> {
  const d = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)));
  return Array.from(d, (b) => b.toString(16).padStart(2, "0")).join("");
}

export async function knownHostID(endpoint: string): Promise<string> {
  return "kh-" + (await sha256hex(endpoint)).slice(0, 40);
}

async function snapshot(d: WebData): Promise<Map<string, Item>> {
  const out = new Map<string, Item>();
  const put = (id: string, kind: string, value: unknown, updatedAt: number) => out.set(id, { kind, body: stable(value), updatedAt });
  for (const h of d.hosts) {
    put(h.id, "host", { ...h, lastConnected: undefined }, h.updatedAt);
    const pw = d.secrets["pw-" + h.id];
    if (h.hasPassword && pw) put("pw-" + h.id, "secret", { value: pw.value }, h.updatedAt);
  }
  for (const g of d.groups) put(g.id, "group", g, g.updatedAt);
  for (const i of d.identities) {
    put(i.id, "identity", i, i.updatedAt);
    const k = d.secrets["key-" + i.id];
    if (i.syncPrivateKey && k) put("key-" + i.id, "secret", k, i.updatedAt);
  }
  for (const s of d.snippets) put(s.id, "snippet", s, s.updatedAt);
  for (const k of d.knownHosts) put(await knownHostID(k.endpoint), "known_host", { key: k }, k.addedAt);
  return out;
}

function upsert<T extends { id: string }>(list: T[], item: T) {
  const i = list.findIndex((x) => x.id === item.id);
  if (i >= 0) list[i] = item; else list.push(item);
}

function applyBody(d: WebData, id: string, kind: string, body: string) {
  const v = JSON.parse(body);
  switch (kind) {
    case "host": {
      const h = v as Host;
      const local = d.hosts.find((x) => x.id === h.id);
      h.lastConnected = local?.lastConnected;
      h.hasPassword = local?.hasPassword ?? !!d.secrets["pw-" + h.id];
      upsert(d.hosts, h);
      break;
    }
    case "group": upsert(d.groups, v as HostGroup); break;
    case "identity": upsert(d.identities, v as Identity); break;
    case "snippet": upsert(d.snippets, v as Snippet); break;
    case "known_host": {
      const k = (v as { key: KnownHostKey }).key;
      // Never replace a different stored key for the same endpoint.
      if (!d.knownHosts.some((x) => x.endpoint === k.endpoint)) d.knownHosts.push(k);
      break;
    }
    case "secret": {
      d.secrets[id] = v as Secret;
      if (id.startsWith("pw-")) {
        const h = d.hosts.find((x) => x.id === id.slice(3));
        if (h) h.hasPassword = true;
      }
      break;
    }
  }
}

function applyDelete(d: WebData, id: string, kind: string) {
  switch (kind) {
    case "host": d.hosts = d.hosts.filter((h) => h.id !== id); delete d.secrets["pw-" + id]; break;
    case "group": d.groups = d.groups.filter((g) => g.id !== id); break;
    case "identity": d.identities = d.identities.filter((i) => i.id !== id); delete d.secrets["key-" + id]; break;
    case "snippet": d.snippets = d.snippets.filter((s) => s.id !== id); break;
    case "secret":
      if (id.startsWith("pw-")) {
        delete d.secrets[id];
        const h = d.hosts.find((x) => x.id === id.slice(3));
        if (h) h.hasPassword = false;
      }
      break;
  }
}

async function decryptRecord(c: SyncCredentials, r: ServerRecord): Promise<{ updatedAt: number; body: string } | null> {
  if (r.deleted || !r.ciphertext) return null;
  const key = await recordKey(vk(c, r.epoch), c.vaultID);
  const env = JSON.parse(new TextDecoder().decode(await open(unb64(r.ciphertext), key, recordAAD(c.vaultID, r.id, r.kind))));
  return { updatedAt: env.updatedAt, body: new TextDecoder().decode(unb64(env.body)) };
}

/// Pull, merge (newest edit wins), push. Mutates `d`.
export async function sync(c: SyncCredentials, d: WebData): Promise<{ pulled: number; pushed: number }> {
  let pulled = 0, pushed = 0;

  const merge = async (r: ServerRecord) => {
    const meta = d.sync.meta[r.id];
    if (meta && meta.serverVersion >= r.version) return;
    const snap = await snapshot(d);
    const local = snap.get(r.id);
    const dirty = local ? !meta || meta.hash !== (await sha256hex(local.body)) : !!meta && meta.hash !== "deleted";
    const remote = await decryptRecord(c, r);
    if (dirty) {
      const localTime = local?.updatedAt ?? meta?.updatedAt ?? 0;
      if (localTime > (remote?.updatedAt ?? 0)) {
        d.sync.meta[r.id] = { kind: r.kind, serverVersion: r.version, hash: "rebase", updatedAt: localTime };
        return;
      }
    }
    if (remote) applyBody(d, r.id, r.kind, remote.body);
    else applyDelete(d, r.id, r.kind);
    const after = (await snapshot(d)).get(r.id);
    d.sync.meta[r.id] = {
      kind: r.kind, serverVersion: r.version,
      hash: remote ? await sha256hex(after?.body ?? remote.body) : "deleted",
      updatedAt: remote?.updatedAt ?? Date.now(),
    };
  };

  for (;;) {
    const page = await api<{ records: ServerRecord[]; cursor: number; more: boolean }>(c.serverURL, "GET", `v1/records?since=${d.sync.cursor}`, c.token);
    for (const r of page.records) { await merge(r); pulled++; }
    d.sync.cursor = page.cursor;
    if (!page.more) break;
  }

  for (let round = 0; round < 3; round++) {
    const snap = await snapshot(d);
    const ids = new Set([...snap.keys(), ...Object.keys(d.sync.meta)]);
    const key = await recordKey(vk(c, c.epoch), c.vaultID);
    const batch: unknown[] = [];
    const hashes = new Map<string, string>();
    for (const id of ids) {
      const item = snap.get(id);
      const meta = d.sync.meta[id];
      if (item) {
        const h = await sha256hex(item.body);
        if (meta && meta.hash === h) continue;
        hashes.set(id, h);
        const env = JSON.stringify({ updatedAt: item.updatedAt, body: b64(new TextEncoder().encode(item.body)) });
        batch.push({ id, kind: item.kind, base_version: meta?.serverVersion ?? 0, epoch: c.epoch, deleted: false,
          ciphertext: b64(await seal(new TextEncoder().encode(env), key, recordAAD(c.vaultID, id, item.kind))) });
      } else if (meta && meta.hash !== "deleted") {
        hashes.set(id, "deleted");
        batch.push({ id, kind: meta.kind, base_version: meta.serverVersion, epoch: c.epoch, deleted: true, ciphertext: null });
      }
    }
    if (batch.length === 0) break;
    const resp = await api<{ applied: { id: string; version: number }[]; conflicts: ServerRecord[] }>(c.serverURL, "POST", "v1/records", c.token, { records: batch });
    for (const a of resp.applied) {
      const item = snap.get(a.id);
      d.sync.meta[a.id] = { kind: item?.kind ?? d.sync.meta[a.id].kind, serverVersion: a.version, hash: hashes.get(a.id)!, updatedAt: item?.updatedAt ?? Date.now() };
      pushed++;
    }
    for (const r of resp.conflicts) await merge(r);
  }
  d.sync.lastSync = Date.now();
  return { pulled, pushed };
}
