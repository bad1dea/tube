// Mirrors TubeCore models. Field names and required fields must match the
// Swift Codable types or iOS will drop synced records it cannot decode.
// Dates are milliseconds since 1970, ids are upper-case UUIDs (Swift's form).

export interface TerminalSettings {
  themeName: string;
  fontName: string;
  fontSize: number;
  backspaceSendsControlH: boolean;
}

export interface Host {
  id: string;
  label: string;
  hostname: string;
  port: number;
  username: string;
  identityID?: string;
  hasPassword: boolean;
  jumpHostIDs: string[];
  groupID?: string;
  tags: string[];
  favorite: boolean;
  notes: string;
  terminal?: TerminalSettings;
  lastConnected?: number;
  updatedAt: number;
}

export interface HostGroup {
  id: string;
  name: string;
  parentID?: string;
  updatedAt: number;
}

export interface Identity {
  id: string;
  label: string;
  algorithm: "ssh-ed25519" | "ssh-rsa" | "ecdsa-sha2-nistp256";
  publicKey: string;
  hasPassphrase: boolean;
  syncPrivateKey: boolean;
  updatedAt: number;
}

export interface Snippet {
  id: string;
  name: string;
  command: string;
  folder: string;
  runImmediately: boolean;
  updatedAt: number;
}

export interface KnownHostKey {
  endpoint: string;
  algorithm: string;
  keyBase64: string;
  addedAt: number;
}

export interface Secret {
  value: string;
  passphrase?: string;
}

export interface SyncCredentials {
  serverURL: string;
  vaultID: string;
  deviceID: string;
  token: string;
  epoch: number;
  keys: Record<number, string>; // epoch -> base64 VK
  kek: string;
}

export interface RecordMeta {
  kind: string;
  serverVersion: number;
  hash: string;
  updatedAt: number;
}

export interface WebSettings {
  gatewayURL: string;
  gatewayToken: string;
  themeName: string;
  fontSize: number;
}

export interface WebData {
  hosts: Host[];
  groups: HostGroup[];
  identities: Identity[];
  snippets: Snippet[];
  knownHosts: KnownHostKey[];
  /// "pw-<hostID>" and "key-<identityID>", same ids as sync secret records.
  secrets: Record<string, Secret>;
  settings: WebSettings;
  history: string[];
  sync: { creds?: SyncCredentials; cursor: number; meta: Record<string, RecordMeta>; lastSync?: number };
}

export function emptyData(): WebData {
  return {
    hosts: [], groups: [], identities: [], snippets: [], knownHosts: [], secrets: {}, history: [],
    settings: { gatewayURL: "", gatewayToken: "", themeName: "Tube Dark", fontSize: 14 },
    sync: { cursor: 0, meta: {} },
  };
}

export const newID = () => globalThis.crypto.randomUUID().toUpperCase();

export function newHost(): Host {
  return {
    id: newID(), label: "", hostname: "", port: 22, username: "", hasPassword: false, jumpHostIDs: [],
    tags: [], favorite: false, notes: "", updatedAt: Date.now(),
  };
}

export const displayName = (h: Host) => h.label || h.hostname;

export function destination(h: Host): string {
  const host = h.hostname.includes(":") ? `[${h.hostname}]` : h.hostname;
  return h.port === 22 ? `${h.username}@${host}` : `${h.username}@${host}:${h.port}`;
}

export function snippetVariables(cmd: string): string[] {
  const seen: string[] = [];
  for (const m of cmd.matchAll(/\{\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*\}\}/g)) {
    if (!seen.includes(m[1])) seen.push(m[1]);
  }
  return seen;
}

export function renderSnippet(cmd: string, values: Record<string, string>): string {
  return cmd.replace(/\{\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*\}\}/g, (all, name) => values[name] ?? all);
}

export function knownHostsCheck(keys: KnownHostKey[], host: string, port: number, keyBase64: string):
  { kind: "trusted" } | { kind: "unknown" } | { kind: "changed"; expected: string } {
  const ep = `${host.toLowerCase()}:${port}`;
  const stored = keys.filter((k) => k.endpoint === ep);
  if (stored.length === 0) return { kind: "unknown" };
  if (stored.some((k) => k.keyBase64 === keyBase64)) return { kind: "trusted" };
  return { kind: "changed", expected: stored[0].keyBase64 };
}
