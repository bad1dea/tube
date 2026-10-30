import { useEffect, useState, type ReactNode } from "react";
import type { Host, Identity, Snippet, WebData } from "./model.ts";
import { destination, displayName, newID, snippetVariables } from "./model.ts";
import { loadSSH } from "./ssh.ts";
import * as syncAPI from "./vault/sync.ts";
import { themes } from "./themes.ts";
import { QRCode } from "./QRCode.tsx";

type Commit = (mutate?: (d: WebData) => void) => void;

export function Modal({ title, onClose, children, wide }: { title: string; onClose: () => void; children: ReactNode; wide?: boolean }) {
  useEffect(() => {
    const esc = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", esc);
    return () => window.removeEventListener("keydown", esc);
  }, [onClose]);
  return (
    <div className="modal-bg" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className={`modal ${wide ? "wide" : ""}`} role="dialog" aria-label={title}>
        <header><h2>{title}</h2><button className="x" aria-label="Close" onClick={onClose}>×</button></header>
        <div className="modal-body">{children}</div>
      </div>
    </div>
  );
}

export function HostEditor({ host, data, onSave, onDelete, onClose, commit }: {
  host: Host; data: WebData; onSave: (h: Host, password?: string) => void; onDelete: (id: string) => void; onClose: () => void; commit: Commit;
}) {
  const [h, setH] = useState(host);
  const [password, setPassword] = useState<string | undefined>(undefined);
  const [tags, setTags] = useState(host.tags.join(" "));
  const [newGroup, setNewGroup] = useState("");
  const isNew = !data.hosts.some((x) => x.id === host.id);
  const set = <K extends keyof Host>(k: K, v: Host[K]) => setH({ ...h, [k]: v });
  const others = data.hosts.filter((x) => x.id !== h.id && !h.jumpHostIDs.includes(x.id));
  const jumps = h.jumpHostIDs.map((id) => data.hosts.find((x) => x.id === id)?.username + "@" + data.hosts.find((x) => x.id === id)?.hostname);
  const valid = h.hostname.trim() && h.username.trim() && h.port > 0 && h.port < 65536;

  return (
    <Modal title={isNew ? "New host" : displayName(host)} onClose={onClose}>
      <form onSubmit={(e) => { e.preventDefault(); if (valid) onSave({ ...h, hostname: h.hostname.trim(), tags: tags.split(/\s+/).filter(Boolean) }, password); }}>
        <div className="grid2">
          <label>Label<input value={h.label} onChange={(e) => set("label", e.target.value)} /></label>
          <label>Host or IP<input value={h.hostname} required onChange={(e) => set("hostname", e.target.value)} autoFocus={isNew} /></label>
          <label>Port<input type="number" min={1} max={65535} value={h.port} onChange={(e) => set("port", Number(e.target.value))} /></label>
          <label>Username<input value={h.username} required onChange={(e) => set("username", e.target.value)} /></label>
          <label>Identity
            <select value={h.identityID ?? ""} onChange={(e) => set("identityID", e.target.value || undefined)}>
              <option value="">None (password)</option>
              {data.identities.map((i) => <option key={i.id} value={i.id}>{i.label}</option>)}
            </select>
          </label>
          <label>Password
            <input type="password" autoComplete="new-password" placeholder={h.hasPassword && password === undefined ? "saved (unchanged)" : ""}
              value={password ?? ""} onChange={(e) => setPassword(e.target.value)} />
          </label>
        </div>

        <fieldset>
          <legend>Jump hosts</legend>
          <ol className="jumps">
            {h.jumpHostIDs.map((id, i) => {
              const j = data.hosts.find((x) => x.id === id);
              return (
                <li key={id}>
                  {j ? `${displayName(j)} (${destination(j)})` : "deleted host"}
                  <button type="button" onClick={() => set("jumpHostIDs", h.jumpHostIDs.filter((x) => x !== id))}>Remove</button>
                  {i > 0 && <button type="button" onClick={() => { const a = [...h.jumpHostIDs]; [a[i - 1], a[i]] = [a[i], a[i - 1]]; set("jumpHostIDs", a); }}>Up</button>}
                </li>
              );
            })}
          </ol>
          {others.length > 0 && (
            <select value="" onChange={(e) => e.target.value && set("jumpHostIDs", [...h.jumpHostIDs, e.target.value])}>
              <option value="">Add jump host…</option>
              {others.map((x) => <option key={x.id} value={x.id}>{displayName(x)}</option>)}
            </select>
          )}
          <p className="mono muted small">ssh{jumps.length ? ` -J ${jumps.join(",")}` : ""}{h.port !== 22 ? ` -p ${h.port}` : ""} {h.username || "user"}@{h.hostname || "host"}</p>
        </fieldset>

        <div className="grid2">
          <label>Group
            <select value={h.groupID ?? ""} onChange={(e) => set("groupID", e.target.value || undefined)}>
              <option value="">None</option>
              {data.groups.map((g) => <option key={g.id} value={g.id}>{g.name}</option>)}
            </select>
          </label>
          <label>New group
            <span className="row">
              <input value={newGroup} onChange={(e) => setNewGroup(e.target.value)} />
              <button type="button" disabled={!newGroup.trim()} onClick={() => {
                const g = { id: newID(), name: newGroup.trim(), updatedAt: Date.now() };
                commit((d) => d.groups.push(g));
                set("groupID", g.id);
                setNewGroup("");
              }}>Add</button>
            </span>
          </label>
          <label>Tags<input value={tags} onChange={(e) => setTags(e.target.value)} placeholder="space separated" /></label>
          <label className="check"><input type="checkbox" checked={h.favorite} onChange={(e) => set("favorite", e.target.checked)} /> Favorite</label>
        </div>
        <label>Notes<textarea rows={3} value={h.notes} onChange={(e) => set("notes", e.target.value)} /></label>
        <div className="actions">
          {!isNew && <button type="button" className="danger" onClick={() => confirm(`Delete ${displayName(h)}?`) && onDelete(h.id)}>Delete</button>}
          <span className="spacer" />
          <button type="button" onClick={onClose}>Cancel</button>
          <button type="submit" className="primary" disabled={!valid}>Save</button>
        </div>
      </form>
    </Modal>
  );
}

export function IdentitiesPanel({ data, commit, onClose }: { data: WebData; commit: Commit; onClose: () => void }) {
  const [label, setLabel] = useState("");
  const [keyText, setKeyText] = useState("");
  const [passphrase, setPassphrase] = useState("");
  const [error, setError] = useState("");

  const add = (privateKey: string, publicKey: string, pass: string) => {
    const alg = publicKey.split(" ")[0] as Identity["algorithm"];
    const ident: Identity = { id: newID(), label: label || "key", algorithm: alg, publicKey, hasPassphrase: !!pass, syncPrivateKey: false, updatedAt: Date.now() };
    commit((d) => {
      d.identities.push(ident);
      d.secrets["key-" + ident.id] = { value: privateKey, ...(pass ? { passphrase: pass } : {}) };
    });
    setLabel(""); setKeyText(""); setPassphrase(""); setError("");
  };

  return (
    <Modal title="Identities" onClose={onClose} wide>
      <table className="list">
        <tbody>
          {data.identities.map((i) => (
            <tr key={i.id}>
              <td>{i.label}<div className="muted small">{i.algorithm}{i.hasPassphrase ? ", passphrase" : ""}</div></td>
              <td className="mono small ellipsis" title={i.publicKey}>{i.publicKey}</td>
              <td className="nowrap">
                <button onClick={() => navigator.clipboard.writeText(i.publicKey)}>Copy public key</button>
                <label className="check small"><input type="checkbox" checked={i.syncPrivateKey}
                  onChange={(e) => commit((d) => { const x = d.identities.find((y) => y.id === i.id)!; x.syncPrivateKey = e.target.checked; x.updatedAt = Date.now(); })} /> sync private key</label>
                <button className="danger" onClick={() => confirm(`Delete ${i.label}?`) && commit((d) => {
                  d.identities = d.identities.filter((y) => y.id !== i.id);
                  delete d.secrets["key-" + i.id];
                  d.hosts.forEach((h) => { if (h.identityID === i.id) h.identityID = undefined; });
                })}>Delete</button>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
      {data.identities.length === 0 && <p className="muted">No identities.</p>}
      <h3>Add</h3>
      <label>Label<input value={label} onChange={(e) => setLabel(e.target.value)} placeholder="laptop-2026" /></label>
      <div className="actions left">
        <button onClick={async () => {
          const ssh = await loadSSH();
          const k = ssh.generateKey(label || "tube-web");
          add(k.privateKey, k.publicKey, "");
        }}>Generate Ed25519</button>
      </div>
      <label>Or paste an OpenSSH private key<textarea className="mono" rows={5} value={keyText} onChange={(e) => setKeyText(e.target.value)} /></label>
      <label>Passphrase<input type="password" value={passphrase} onChange={(e) => setPassphrase(e.target.value)} /></label>
      {error && <p className="warn">{error}</p>}
      <div className="actions left">
        <button disabled={!keyText.trim()} onClick={async () => {
          const ssh = await loadSSH();
          const pub = ssh.publicKey(keyText.trim() + "\n", passphrase);
          if (pub instanceof Error) return setError(pub.message);
          add(keyText.trim() + "\n", pub, passphrase);
        }}>Import</button>
      </div>
    </Modal>
  );
}

export function SnippetsPanel({ data, commit, onClose }: { data: WebData; commit: Commit; onClose: () => void }) {
  const blank = (): Snippet => ({ id: newID(), name: "", command: "", folder: "", runImmediately: true, updatedAt: Date.now() });
  const [s, setS] = useState<Snippet>(blank());
  const exists = data.snippets.some((x) => x.id === s.id);
  return (
    <Modal title="Snippets" onClose={onClose} wide>
      <table className="list">
        <tbody>
          {data.snippets.map((x) => (
            <tr key={x.id}>
              <td>{x.name}</td>
              <td className="mono small ellipsis">{x.command}</td>
              <td className="nowrap">
                <button onClick={() => setS({ ...x })}>Edit</button>
                <button className="danger" onClick={() => commit((d) => { d.snippets = d.snippets.filter((y) => y.id !== x.id); })}>Delete</button>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
      <h3>{exists ? "Edit snippet" : "New snippet"}</h3>
      <label>Name<input value={s.name} onChange={(e) => setS({ ...s, name: e.target.value })} /></label>
      <label>Command<textarea className="mono" rows={3} value={s.command} onChange={(e) => setS({ ...s, command: e.target.value })} placeholder="journalctl -u {{unit}} -n 100" /></label>
      {snippetVariables(s.command).length > 0 && <p className="muted small">Asks for: {snippetVariables(s.command).join(", ")}</p>}
      <label className="check"><input type="checkbox" checked={s.runImmediately} onChange={(e) => setS({ ...s, runImmediately: e.target.checked })} /> Press return after inserting</label>
      <div className="actions left">
        <button className="primary" disabled={!s.name || !s.command} onClick={() => {
          commit((d) => {
            const v = { ...s, updatedAt: Date.now() };
            const i = d.snippets.findIndex((y) => y.id === v.id);
            if (i >= 0) d.snippets[i] = v; else d.snippets.push(v);
          });
          setS(blank());
        }}>Save</button>
      </div>
    </Modal>
  );
}

export function SettingsPanel({ data, commit, onClose }: { data: WebData; commit: Commit; onClose: () => void }) {
  const st = data.settings;
  return (
    <Modal title="Settings" onClose={onClose} wide>
      <h3>Gateway</h3>
      <p className="muted small">The browser cannot open TCP connections, so SSH traffic goes through a tube-gateway relay. SSH itself runs in this page: the gateway carries encrypted bytes and never sees passwords, keys or terminal contents. It does see which host and port you connect to.</p>
      <label>Relay URL<input value={st.gatewayURL} placeholder="wss://gateway.example.com/relay" onChange={(e) => commit((d) => { d.settings.gatewayURL = e.target.value.trim(); })} /></label>
      <label>Token<input type="password" value={st.gatewayToken} onChange={(e) => commit((d) => { d.settings.gatewayToken = e.target.value.trim(); })} /></label>
      <h3>Terminal</h3>
      <div className="grid2">
        <label>Theme
          <select value={st.themeName} onChange={(e) => commit((d) => { d.settings.themeName = e.target.value; })}>
            {Object.keys(themes).map((t) => <option key={t}>{t}</option>)}
          </select>
        </label>
        <label>Font size<input type="number" min={8} max={32} value={st.fontSize} onChange={(e) => commit((d) => { d.settings.fontSize = Number(e.target.value); })} /></label>
      </div>
      <h3>Known hosts</h3>
      <table className="list">
        <tbody>
          {data.knownHosts.map((k) => (
            <tr key={k.endpoint + k.keyBase64}>
              <td className="mono">{k.endpoint}</td>
              <td className="mono small">{k.algorithm}</td>
              <td><button className="danger" onClick={() => commit((d) => { d.knownHosts = d.knownHosts.filter((x) => x !== k && x.endpoint !== k.endpoint); })}>Forget</button></td>
            </tr>
          ))}
        </tbody>
      </table>
      {data.knownHosts.length === 0 && <p className="muted">None yet.</p>}
    </Modal>
  );
}

export function SyncPanel({ data, commit, runSync, onClose }: { data: WebData; commit: Commit; runSync: () => Promise<void>; onClose: () => void }) {
  const creds = data.sync.creds;
  const [server, setServer] = useState("https://");
  const [registration, setRegistration] = useState("");
  const [code, setCode] = useState("");
  const [vaultID, setVaultID] = useState("");
  const [rk, setRK] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [created, setCreated] = useState<string | null>(null);
  const [invite, setInvite] = useState("");
  const [devices, setDevices] = useState<syncAPI.DeviceInfo[]>([]);
  const name = `Browser (${navigator.platform || "web"})`;

  useEffect(() => {
    if (creds) syncAPI.devices(creds).then(setDevices).catch((e) => setError(String(e.message ?? e)));
  }, [creds?.token]);

  const run = (fn: () => Promise<void>) => async () => {
    setBusy(true); setError("");
    try { await fn(); } catch (e) { setError(e instanceof Error ? e.message : String(e)); }
    setBusy(false);
  };
  const adopt = async (c: typeof creds) => {
    commit((d) => { d.sync = { creds: c, cursor: 0, meta: {} }; });
    await runSync();
  };

  if (!creds) {
    return (
      <Modal title="Sync" onClose={onClose} wide>
        <p className="muted">Off. Data stays in this browser, encrypted with your passphrase. Sync uses a server you run (docker compose up -d); data is encrypted here before upload.</p>
        <h3>Join with a pairing code</h3>
        <label>Code<input className="mono" value={code} onChange={(e) => setCode(e.target.value)} placeholder="tube://pair?..." /></label>
        <div className="actions left"><button disabled={busy || !code} onClick={run(async () => adopt(await syncAPI.claim(code, name)))}>Join</button></div>
        <h3>Recover</h3>
        <div className="grid2">
          <label>Server<input value={server} onChange={(e) => setServer(e.target.value)} /></label>
          <label>Vault id<input className="mono" value={vaultID} onChange={(e) => setVaultID(e.target.value)} /></label>
        </div>
        <label>Recovery key<input className="mono" value={rk} onChange={(e) => setRK(e.target.value)} /></label>
        <div className="actions left"><button disabled={busy || !vaultID || !rk} onClick={run(async () => adopt(await syncAPI.recover(server, vaultID.trim(), rk, name)))}>Recover</button></div>
        <h3>Create a new vault</h3>
        <div className="grid2">
          <label>Server<input value={server} onChange={(e) => setServer(e.target.value)} /></label>
          <label>Registration token<input type="password" value={registration} onChange={(e) => setRegistration(e.target.value)} /></label>
        </div>
        <div className="actions left"><button disabled={busy} onClick={run(async () => {
          const r = await syncAPI.createVault(server, name, registration || undefined);
          setCreated(`Vault ${r.creds.vaultID}\nRecovery key ${r.recoveryKey}`);
          await adopt(r.creds);
        })}>Create</button></div>
        {error && <p className="warn">{error}</p>}
      </Modal>
    );
  }

  return (
    <Modal title="Sync" onClose={onClose} wide>
      {created && (
        <div className="callout">
          <p>Write this down. It is shown once and is the only way back in if every device is lost.</p>
          <pre className="mono">{created}</pre>
          <button onClick={() => navigator.clipboard.writeText(created)}>Copy</button>
        </div>
      )}
      <dl className="kv">
        <dt>Server</dt><dd>{creds.serverURL}</dd>
        <dt>Vault</dt><dd className="mono">{creds.vaultID}</dd>
        <dt>Key epoch</dt><dd>{creds.epoch}</dd>
        <dt>Last sync</dt><dd>{data.sync.lastSync ? new Date(data.sync.lastSync).toLocaleString() : "never"}</dd>
      </dl>
      <div className="actions left">
        <button disabled={busy} onClick={run(runSync)}>Sync now</button>
        <button disabled={busy} onClick={run(async () => setInvite(await syncAPI.invite(creds)))}>Show pairing code</button>
      </div>
      {invite && (
        <>
          <p className="muted small">Valid 10 minutes, one device. On iPhone or iPad, scan it in Sync &gt; Join with a Pairing Code, or with the Camera app. Elsewhere, paste it.</p>
          <QRCode text={invite} label="Pairing QR code" />
          <pre className="mono wrap">{invite}</pre>
          <div className="actions left"><button onClick={() => navigator.clipboard.writeText(invite)}>Copy</button></div>
        </>
      )}
      <h3>Devices</h3>
      <table className="list">
        <tbody>
          {devices.map((dv) => (
            <tr key={dv.id}>
              <td>{dv.name}{dv.current ? " (this browser)" : ""}</td>
              <td className="muted small">{dv.revoked ? "revoked" : `seen ${new Date(dv.last_seen * 1000).toLocaleString()}`}</td>
              <td>{!dv.current && !dv.revoked && (
                <button className="danger" disabled={busy} onClick={run(async () => {
                  const next = await syncAPI.revokeAndRotate(creds, dv.id, data);
                  commit((d) => { d.sync.creds = next; });
                  setDevices(await syncAPI.devices(next));
                })}>Revoke</button>
              )}</td>
            </tr>
          ))}
        </tbody>
      </table>
      <p className="muted small">Revoking also rotates the vault key so the revoked device cannot read later changes.</p>
      <div className="actions left"><button className="danger" onClick={() => commit((d) => { d.sync = { cursor: 0, meta: {} }; })}>Stop syncing in this browser</button></div>
      {error && <p className="warn">{error}</p>}
    </Modal>
  );
}
