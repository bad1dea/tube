import { useEffect, useRef, useState } from "react";
import { Terminal as XTerm } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { WebLinksAddon } from "@xterm/addon-web-links";
import "@xterm/xterm/css/xterm.css";
import { loadSSH, type Hop, type SSHSession } from "./ssh.ts";
import { ctrl, encodeKey, type Key } from "./keys.ts";
import { themes } from "./themes.ts";

export interface TabSpec {
  id: string;
  title: string;
  hops: Hop[];
}

interface Props {
  tab: TabSpec;
  active: boolean;
  relayURL: string;
  relayToken: string;
  themeName: string;
  fontSize: number;
  verifyHostKey: (host: string, port: number, algorithm: string, keyBase64: string, fingerprint: string) => Promise<boolean>;
  registerSender: (id: string, send: ((s: string) => void) | null) => void;
  onStatus: (id: string, status: string) => void;
}

export function TerminalTab({ tab, active, relayURL, relayToken, themeName, fontSize, verifyHostKey, registerSender, onStatus }: Props) {
  const host = useRef<HTMLDivElement>(null);
  const term = useRef<XTerm | null>(null);
  const fit = useRef<FitAddon | null>(null);
  const session = useRef<SSHSession | null>(null);
  const [state, setState] = useState<"connecting" | "connected" | "closed">("connecting");
  const [error, setError] = useState("");
  const [attempt, setAttempt] = useState(0);
  const [ctrlArmed, setCtrlArmed] = useState(false);
  const ctrlRef = useRef(false);
  ctrlRef.current = ctrlArmed;

  useEffect(() => {
    const t = new XTerm({
      fontFamily: 'ui-monospace, "SF Mono", Menlo, Consolas, monospace',
      fontSize,
      theme: themes[themeName] ?? themes["Conch Dark"],
      cursorBlink: true,
      scrollback: 10000,
      allowProposedApi: true,
    });
    const f = new FitAddon();
    t.loadAddon(f);
    t.loadAddon(new WebLinksAddon());
    t.open(host.current!);
    f.fit();
    term.current = t;
    fit.current = f;
    const ro = new ResizeObserver(() => {
      try {
        f.fit();
      } catch { /* hidden */ }
    });
    ro.observe(host.current!);
    t.onResize(({ cols, rows }) => session.current?.resize(cols, rows));
    t.onData((d) => {
      if (ctrlRef.current && d.length === 1) {
        d = ctrl(d);
        setCtrlArmed(false);
      }
      session.current?.write(d);
    });
    return () => {
      ro.disconnect();
      session.current?.close();
      t.dispose();
    };
  }, []);

  useEffect(() => {
    if (term.current) {
      term.current.options.theme = themes[themeName] ?? themes["Conch Dark"];
      term.current.options.fontSize = fontSize;
      fit.current?.fit();
    }
  }, [themeName, fontSize]);

  useEffect(() => {
    const t = term.current!;
    let cancelled = false;
    setState("connecting");
    setError("");
    onStatus(tab.id, "connecting");
    t.write(`\r\nConnecting to ${tab.hops.map((h) => `${h.user}@${h.host}:${h.port}`).join(" -> ")}...\r\n`);
    (async () => {
      try {
        const ssh = await loadSSH();
        const s = await ssh.connect({
          relayURL, token: relayToken, hops: tab.hops, cols: t.cols, rows: t.rows,
          onData: (b) => t.write(b),
          onClose: (reason) => {
            setState("closed");
            onStatus(tab.id, "closed");
            t.write(`\r\n[connection closed${reason ? `: ${reason}` : ""}]\r\n`);
          },
          verifyHostKey,
        });
        if (cancelled) return s.close();
        session.current = s;
        registerSender(tab.id, (str) => s.write(str));
        setState("connected");
        onStatus(tab.id, "connected");
        t.focus();
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        setError(msg);
        setState("closed");
        onStatus(tab.id, "closed");
        t.write(`\r\n\x1b[31m${msg}\x1b[0m\r\n`);
      }
    })();
    return () => {
      cancelled = true;
      registerSender(tab.id, null);
      session.current?.close();
      session.current = null;
    };
  }, [attempt]);

  useEffect(() => {
    if (active) {
      requestAnimationFrame(() => {
        fit.current?.fit();
        term.current?.focus();
      });
    }
  }, [active]);

  const press = (k: Key) => {
    const app = term.current?.modes.applicationCursorKeysMode ?? false;
    session.current?.write(encodeKey(k, app));
    term.current?.focus();
  };

  return (
    <div className="term-wrap" style={{ display: active ? "flex" : "none" }}>
      <div className="term" ref={host} />
      {state === "closed" && (
        <div className="term-banner">
          <span>{error || "Disconnected"}</span>
          <button onClick={() => setAttempt((a) => a + 1)}>Reconnect</button>
        </div>
      )}
      <div className="touch-keys">
        <button onClick={() => press("esc")}>esc</button>
        <button onClick={() => press("tab")}>tab</button>
        <button className={ctrlArmed ? "on" : ""} onClick={() => { setCtrlArmed(!ctrlArmed); term.current?.focus(); }}>ctrl</button>
        <button onClick={() => { session.current?.write("\x03"); term.current?.focus(); }}>^C</button>
        <button onClick={() => press("left")}>←</button>
        <button onClick={() => press("down")}>↓</button>
        <button onClick={() => press("up")}>↑</button>
        <button onClick={() => press("right")}>→</button>
        <button onClick={() => { session.current?.write("|"); term.current?.focus(); }}>|</button>
        <button onClick={() => { session.current?.write("/"); term.current?.focus(); }}>/</button>
        <button onClick={() => { session.current?.write("~"); term.current?.focus(); }}>~</button>
        <button onClick={() => { session.current?.write("-"); term.current?.focus(); }}>-</button>
      </div>
    </div>
  );
}
