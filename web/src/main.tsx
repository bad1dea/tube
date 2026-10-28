import { StrictMode, useState } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App.tsx";
import { hasVault, LocalVault } from "./vault/store.ts";
import type { WebData } from "./model.ts";
import "./styles.css";

function Unlock({ onOpen }: { onOpen: (v: LocalVault, d: WebData) => void }) {
  const exists = hasVault();
  const [pass, setPass] = useState("");
  const [pass2, setPass2] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setBusy(true);
    setError("");
    try {
      if (exists) {
        const [v, d] = await LocalVault.unlock(pass);
        onOpen(v, d);
      } else {
        if (pass.length < 8) throw new Error("Use at least 8 characters");
        if (pass !== pass2) throw new Error("Passphrases differ");
        const [v, d] = await LocalVault.create(pass);
        onOpen(v, d);
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
    setBusy(false);
  };

  return (
    <form className="unlock" onSubmit={submit}>
      <h1>Conch</h1>
      <p className="muted">{exists ? "Unlock this browser's vault." : "Choose a passphrase for this browser. Hosts and keys are stored encrypted with it."}</p>
      <input type="password" autoFocus placeholder="Passphrase" value={pass} onChange={(e) => setPass(e.target.value)} />
      {!exists && <input type="password" placeholder="Repeat passphrase" value={pass2} onChange={(e) => setPass2(e.target.value)} />}
      <button className="primary" disabled={busy}>{busy ? "Working…" : exists ? "Unlock" : "Create"}</button>
      {error && <p className="warn">{error}</p>}
      {exists && (
        <button type="button" className="link" onClick={() => {
          if (confirm("Erase the vault stored in this browser? Synced data can be restored with a pairing code or recovery key.")) {
            LocalVault.wipe();
            location.reload();
          }
        }}>Forgot passphrase</button>
      )}
    </form>
  );
}

function Root() {
  const [opened, setOpened] = useState<{ v: LocalVault; d: WebData } | null>(null);
  if (!opened) return <Unlock onOpen={(v, d) => setOpened({ v, d })} />;
  return <App vault={opened.v} initial={opened.d} />;
}

createRoot(document.getElementById("root")!).render(<StrictMode><Root /></StrictMode>);

if ("serviceWorker" in navigator && location.protocol === "https:") {
  navigator.serviceWorker.register("/sw.js");
}
