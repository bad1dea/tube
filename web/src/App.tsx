import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { Host, WebData } from "./model.ts";
import { destination, displayName, knownHostsCheck, newHost, renderSnippet, snippetVariables } from "./model.ts";
import { LocalVault } from "./vault/store.ts";
import * as syncAPI from "./vault/sync.ts";
import { TerminalTab, type TabSpec } from "./Terminal.tsx";
import type { Hop } from "./ssh.ts";
import { HostEditor, IdentitiesPanel, Modal, SettingsPanel, SnippetsPanel, SyncPanel } from "./Panels.tsx";

type Panel = "identities" | "snippets" | "sync" | "settings" | null;

interface HostKeyQuestion {
  host: string;
  port: number;
  algorithm: string;
  keyBase64: string;
  fingerprint: string;
  changed: boolean;
  resolve: (ok: boolean) => void;
}

export function App({ vault, initial }: { vault: LocalVault; initial: WebData }) {
  const data = useRef(initial);
  const [, setVersion] = useState(0);
  const [search, setSearch] = useState("");
  const [tabs, setTabs] = useState<TabSpec[]>([]);
  const [active, setActive] = useState<string | null>(null);
  const [status, setStatus] = useState<Record<string, string>>({});
  const [editing, setEditing] = useState<Host | null>(null);
  const [panel, setPanel] = useState<Panel>(null);
  const [question, setQuestion] = useState<HostKeyQuestion | null>(null);
  const [snippetRun, setSnippetRun] = useState<{ id: string; values: Record<string, string> } | null>(null);
  const [syncMsg, setSyncMsg] = useState("");
  const senders = useRef(new Map<string, (s: string) => void>());
  const saveTimer = useRef<number | undefined>(undefined);
  const syncing = useRef(false);

  const d = data.current;

  const runSync = useCallback(async () => {
    const creds = data.current.sync.creds;
    if (!creds || syncing.current) return;
    syncing.current = true;
    try {
      const r = await syncAPI.sync(creds, data.current);
      setSyncMsg(`Synced ${new Date().toLocaleTimeString()} (${r.pulled} in, ${r.pushed} out)`);
      await vault.save(data.current);
      setVersion((v) => v + 1);
    } catch (e) {
      if (e instanceof syncAPI.SyncError && e.status === 401) {
        data.current.sync = { cursor: 0, meta: {} };
        setSyncMsg("This browser was revoked. Sync is off.");
      } else {
        setSyncMsg(e instanceof Error ? e.message : String(e));
      }
    } finally {
      syncing.current = false;
    }
  }, [vault]);

  const commit = useCallback((mutate?: (d: WebData) => void) => {
    mutate?.(data.current);
    setVersion((v) => v + 1);
    clearTimeout(saveTimer.current);
    saveTimer.current = window.setTimeout(async () => {
      await vault.save(data.current);
      void runSync();
    }, 800);
  }, [vault, runSync]);

  useEffect(() => {
    void runSync();
    const t = window.setInterval(() => void runSync(), 60_000);
    return () => clearInterval(t);
  }, [runSync]);

  const verifyHostKey = useCallback((host: string, port: number, algorithm: string, keyBase64: string, fingerprint: string) => {
    const check = knownHostsCheck(data.current.knownHosts, host, port, keyBase64);
    if (check.kind === "trusted") return Promise.resolve(true);
    return new Promise<boolean>((resolve) => {
      setQuestion({
        host, port, algorithm, keyBase64, fingerprint, changed: check.kind === "changed",
        resolve: (ok) => {
          if (ok && check.kind === "unknown") {
            commit((d) => d.knownHosts.push({ endpoint: `${host.toLowerCase()}:${port}`, algorithm, keyBase64, addedAt: Date.now() }));
          }
          setQuestion(null);
          resolve(ok && check.kind === "unknown");
        },
      });
    });
  }, [commit]);

  const hops = (h: Host): Hop[] => {
    const chain = [...h.jumpHostIDs.map((id) => d.hosts.find((x) => x.id === id)).filter((x): x is Host => !!x), h];
    return chain.map((x) => {
      const key = x.identityID ? d.secrets["key-" + x.identityID] : undefined;
      return {
        host: x.hostname, port: x.port, user: x.username,
        password: d.secrets["pw-" + x.id]?.value,
        privateKey: key?.value, passphrase: key?.passphrase,
      };
    });
  };

  const connect = (h: Host) => {
    if (!d.settings.gatewayURL || !d.settings.gatewayToken) {
      setPanel("settings");
      return;
    }
    const tab: TabSpec = { id: crypto.randomUUID(), title: displayName(h), hops: hops(h) };
    setTabs((t) => [...t, tab]);
    setActive(tab.id);
    commit((d) => {
      const x = d.hosts.find((y) => y.id === h.id);
      if (x) x.lastConnected = Date.now();
    });
  };

  const closeTab = (id: string) => {
    setTabs((t) => {
      const rest = t.filter((x) => x.id !== id);
      if (active === id) setActive(rest.at(-1)?.id ?? null);
      return rest;
    });
  };

  const runSnippet = (id: string, values: Record<string, string>) => {
    const s = d.snippets.find((x) => x.id === id);
    const send = active ? senders.current.get(active) : undefined;
    if (!s || !send) return;
    const text = renderSnippet(s.command, values);
    send(text + (s.runImmediately ? "\r" : ""));
    commit((d) => {
      d.history = [text, ...d.history.filter((x) => x !== text)].slice(0, 200);
    });
  };

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase();
    return [...d.hosts]
      .filter((h) => !q || [h.label, h.hostname, h.username, ...h.tags].some((s) => s.toLowerCase().includes(q)))
      .sort((a, b) => displayName(a).localeCompare(displayName(b)));
  }, [d.hosts, search, d]);

  const groups = useMemo(() => {
    const out: { title: string; hosts: Host[] }[] = [];
    const favs = filtered.filter((h) => h.favorite);
    if (favs.length) out.push({ title: "Favorites", hosts: favs });
    for (const g of [...d.groups].sort((a, b) => a.name.localeCompare(b.name))) {
      const hs = filtered.filter((h) => h.groupID === g.id);
      if (hs.length) out.push({ title: g.name, hosts: hs });
    }
    const known = new Set(d.groups.map((g) => g.id));
    const rest = filtered.filter((h) => !h.groupID || !known.has(h.groupID));
    if (rest.length) out.push({ title: out.length ? "Other" : "Hosts", hosts: rest });
    return out;
  }, [filtered, d.groups]);

  return (
    <div className="app">
      <aside className="sidebar">
        <div className="side-head">
          <input className="search" placeholder="Search hosts" value={search} onChange={(e) => setSearch(e.target.value)} />
          <button title="Add host" onClick={() => setEditing(newHost())}>+</button>
        </div>
        <div className="host-list">
          {groups.map((g) => (
            <section key={g.title}>
              <h3>{g.title}</h3>
              {g.hosts.map((h) => (
                <div key={h.id} className="host-row" onDoubleClick={() => connect(h)}>
                  <button className="host-main" onClick={() => connect(h)} title={`Connect to ${destination(h)}`}>
                    <span className="host-name">{displayName(h)}{h.favorite ? " ★" : ""}</span>
                    <span className="host-dest">{destination(h)}{h.jumpHostIDs.length ? ` via ${h.jumpHostIDs.map((id) => d.hosts.find((x) => x.id === id)?.label ?? "?").join(" → ")}` : ""}</span>
                  </button>
                  <button className="host-edit" title="Edit" onClick={() => setEditing(structuredClone(h))}>Edit</button>
                </div>
              ))}
            </section>
          ))}
          {d.hosts.length === 0 && <p className="muted pad">No hosts yet. Add one, or join a synced vault under Sync.</p>}
        </div>
        <nav className="side-foot">
          <button onClick={() => setPanel("identities")}>Identities</button>
          <button onClick={() => setPanel("snippets")}>Snippets</button>
          <button onClick={() => setPanel("sync")}>Sync</button>
          <button onClick={() => setPanel("settings")}>Settings</button>
        </nav>
        {syncMsg && <div className="sync-msg">{syncMsg}</div>}
      </aside>

      <main className="main">
        <div className="tabs" role="tablist">
          {tabs.map((t) => (
            <div key={t.id} role="tab" aria-selected={t.id === active} className={`tab ${t.id === active ? "active" : ""} ${status[t.id] ?? ""}`}>
              <button onClick={() => setActive(t.id)}>{t.title}</button>
              <button className="x" aria-label={`Close ${t.title}`} onClick={() => closeTab(t.id)}>×</button>
            </div>
          ))}
          {active && d.snippets.length > 0 && (
            <select className="snippet-select" value="" onChange={(e) => {
              const s = d.snippets.find((x) => x.id === e.target.value);
              if (!s) return;
              const vars = snippetVariables(s.command);
              if (vars.length) setSnippetRun({ id: s.id, values: Object.fromEntries(vars.map((v) => [v, ""])) });
              else runSnippet(s.id, {});
            }}>
              <option value="">Run snippet…</option>
              {d.snippets.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
            </select>
          )}
        </div>
        <div className="terms">
          {tabs.length === 0 && <div className="empty muted">Pick a host to connect.</div>}
          {tabs.map((t) => (
            <TerminalTab
              key={t.id} tab={t} active={t.id === active}
              relayURL={d.settings.gatewayURL} relayToken={d.settings.gatewayToken}
              themeName={d.settings.themeName} fontSize={d.settings.fontSize}
              verifyHostKey={verifyHostKey}
              registerSender={(id, s) => { if (s) senders.current.set(id, s); else senders.current.delete(id); }}
              onStatus={(id, s) => setStatus((m) => ({ ...m, [id]: s }))}
            />
          ))}
        </div>
      </main>

      {editing && (
        <HostEditor host={editing} data={d} onClose={() => setEditing(null)}
          onSave={(h, password) => commit((d) => {
            h.updatedAt = Date.now();
            if (password !== undefined) {
              if (password) d.secrets["pw-" + h.id] = { value: password };
              else delete d.secrets["pw-" + h.id];
              h.hasPassword = !!password;
            }
            const i = d.hosts.findIndex((x) => x.id === h.id);
            if (i >= 0) d.hosts[i] = h; else d.hosts.push(h);
            setEditing(null);
          })}
          onDelete={(id) => commit((d) => {
            d.hosts = d.hosts.filter((x) => x.id !== id);
            d.hosts.forEach((x) => { x.jumpHostIDs = x.jumpHostIDs.filter((j) => j !== id); });
            delete d.secrets["pw-" + id];
            setEditing(null);
          })}
          commit={commit}
        />
      )}
      {panel === "identities" && <IdentitiesPanel data={d} commit={commit} onClose={() => setPanel(null)} />}
      {panel === "snippets" && <SnippetsPanel data={d} commit={commit} onClose={() => setPanel(null)} />}
      {panel === "settings" && <SettingsPanel data={d} commit={commit} onClose={() => setPanel(null)} />}
      {panel === "sync" && <SyncPanel data={d} commit={commit} runSync={runSync} onClose={() => setPanel(null)} />}

      {question && (
        <Modal title={question.changed ? "Host key changed" : "Unknown host key"} onClose={() => question.resolve(false)}>
          <dl className="kv">
            <dt>Host</dt><dd>{question.host}:{question.port}</dd>
            <dt>Key type</dt><dd>{question.algorithm}</dd>
            <dt>Fingerprint</dt><dd className="mono">{question.fingerprint}</dd>
          </dl>
          {question.changed ? (
            <>
              <p className="warn">The server presented a different key than the one stored for this host. This can mean the server was reinstalled or that someone is intercepting the connection. The connection was refused.</p>
              <p className="muted">If the change is expected, remove the old key under Settings, Known hosts, then connect again.</p>
              <div className="actions"><button onClick={() => question.resolve(false)}>Close</button></div>
            </>
          ) : (
            <>
              <p className="muted">First connection to this host. Compare the fingerprint with <code>ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub</code> on the server.</p>
              <div className="actions">
                <button onClick={() => question.resolve(false)}>Cancel</button>
                <button className="primary" onClick={() => question.resolve(true)}>Trust</button>
              </div>
            </>
          )}
        </Modal>
      )}

      {snippetRun && (
        <Modal title="Snippet values" onClose={() => setSnippetRun(null)}>
          <form onSubmit={(e) => { e.preventDefault(); runSnippet(snippetRun.id, snippetRun.values); setSnippetRun(null); }}>
            {Object.keys(snippetRun.values).map((k) => (
              <label key={k}>{k}
                <input autoFocus value={snippetRun.values[k]} onChange={(e) => setSnippetRun({ ...snippetRun, values: { ...snippetRun.values, [k]: e.target.value } })} />
              </label>
            ))}
            <div className="actions"><button type="submit" className="primary">Run</button></div>
          </form>
        </Modal>
      )}
    </div>
  );
}
