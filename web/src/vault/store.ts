// Browser copy of the vault, encrypted at rest in localStorage with a key
// derived from a passphrase chosen for this browser (PBKDF2-SHA256, 600k).

import { emptyData, type WebData } from "../model.ts";
import { b64, localKey, open, randomBytes, seal, unb64 } from "./crypto.ts";

const KEY = "tube.vault.v1";
const AAD = "tube-local-v1";

interface Stored {
  salt: string;
  iterations: number;
  sealed: string;
}

export const hasVault = () => localStorage.getItem(KEY) !== null;

export class LocalVault {
  private key: Uint8Array;
  private salt: Uint8Array;
  private iterations: number;

  private constructor(key: Uint8Array, salt: Uint8Array, iterations: number) {
    this.key = key;
    this.salt = salt;
    this.iterations = iterations;
  }

  static async create(passphrase: string): Promise<[LocalVault, WebData]> {
    const salt = randomBytes(16);
    const v = new LocalVault(await localKey(passphrase, salt), salt, 600_000);
    const data = emptyData();
    await v.save(data);
    return [v, data];
  }

  static async unlock(passphrase: string): Promise<[LocalVault, WebData]> {
    const raw = localStorage.getItem(KEY);
    if (!raw) throw new Error("No vault in this browser");
    const s = JSON.parse(raw) as Stored;
    const salt = unb64(s.salt);
    const key = await localKey(passphrase, salt, s.iterations);
    let plain: Uint8Array;
    try {
      plain = await open(unb64(s.sealed), key, AAD);
    } catch {
      throw new Error("Wrong passphrase");
    }
    const data = { ...emptyData(), ...JSON.parse(new TextDecoder().decode(plain)) } as WebData;
    return [new LocalVault(key, salt, s.iterations), data];
  }

  async save(data: WebData) {
    const sealed = await seal(new TextEncoder().encode(JSON.stringify(data)), this.key, AAD);
    const s: Stored = { salt: b64(this.salt), iterations: this.iterations, sealed: b64(sealed) };
    localStorage.setItem(KEY, JSON.stringify(s));
  }

  static wipe() {
    localStorage.removeItem(KEY);
  }
}
