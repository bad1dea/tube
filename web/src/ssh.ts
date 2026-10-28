// Loads the Go SSH module (web/sshwasm) once and exposes a typed API.

export interface Hop {
  host: string;
  port: number;
  user: string;
  password?: string;
  privateKey?: string;
  passphrase?: string;
}

export interface ConnectOptions {
  relayURL: string;
  token: string;
  hops: Hop[];
  cols: number;
  rows: number;
  term?: string;
  onData: (b: Uint8Array) => void;
  onClose: (reason: string) => void;
  verifyHostKey: (host: string, port: number, algorithm: string, keyBase64: string, fingerprint: string) => Promise<boolean>;
}

export interface SSHSession {
  write(data: Uint8Array | string): void;
  resize(cols: number, rows: number): void;
  close(): void;
}

interface TubeSSH {
  connect(o: ConnectOptions): Promise<SSHSession>;
  generateKey(comment: string): { privateKey: string; publicKey: string };
  publicKey(privateKey: string, passphrase?: string): string | Error;
}

declare global {
  // eslint-disable-next-line no-var
  var tubeSSH: TubeSSH | undefined;
  // eslint-disable-next-line no-var
  var tubeSSHReady: (() => void) | undefined;
  // eslint-disable-next-line no-var
  var Go: new () => { importObject: WebAssembly.Imports; run(i: WebAssembly.Instance): Promise<void> };
}

let loading: Promise<TubeSSH> | null = null;

export function loadSSH(): Promise<TubeSSH> {
  if (loading) return loading;
  loading = new Promise<TubeSSH>((resolve, reject) => {
    const script = document.createElement("script");
    script.src = "/wasm_exec.js";
    script.onerror = () => reject(new Error("Failed to load wasm_exec.js"));
    script.onload = async () => {
      try {
        globalThis.tubeSSHReady = () => resolve(globalThis.tubeSSH!);
        const go = new globalThis.Go();
        const { instance } = await WebAssembly.instantiateStreaming(fetch("/ssh.wasm"), go.importObject);
        void go.run(instance);
      } catch (e) {
        reject(e);
      }
    };
    document.head.appendChild(script);
  });
  return loading;
}
