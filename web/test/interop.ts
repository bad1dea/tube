// Cross-platform check, driven by test/interop.sh:
//   node interop.ts create <file>   web creates a vault with a host, writes {vaultID, recoveryKey}
//   (Swift test recovers, decodes the host with TubeCore types, pushes a snippet)
//   node interop.ts verify <file>   web recovers and expects the Swift snippet
import { readFileSync, writeFileSync } from "node:fs";
import { emptyData, newHost } from "../src/model.ts";
import * as s from "../src/vault/sync.ts";

const server = process.env.TUBE_SYNC_URL!;
const [, , mode, file] = process.argv;

if (mode === "create") {
  const { creds, recoveryKey } = await s.createVault(server, "web");
  const d = emptyData();
  const jump = { ...newHost(), label: "bastion", hostname: "ctrl.khuo.ng", port: 2222, username: "jump" };
  const h = {
    ...newHost(), label: "lab", hostname: "100.64.0.10", port: 2022, username: "khuong",
    jumpHostIDs: [jump.id], tags: ["lab", "tailnet"], favorite: true, hasPassword: true,
    terminal: { themeName: "Nord", fontName: "Menlo", fontSize: 14, backspaceSendsControlH: false },
  };
  d.hosts.push(jump, h);
  d.secrets["pw-" + h.id] = { value: "from-web" };
  d.knownHosts.push({ endpoint: "100.64.0.10:2022", algorithm: "ssh-ed25519", keyBase64: "AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl", addedAt: Date.now() });
  await s.sync(creds, d);
  writeFileSync(file, JSON.stringify({ vaultID: creds.vaultID, recoveryKey, hostID: h.id, jumpID: jump.id }));
  console.log("created", creds.vaultID);
} else if (mode === "verify") {
  const info = JSON.parse(readFileSync(file, "utf8"));
  const c = await s.recover(server, info.vaultID, info.recoveryKey, "web-verify");
  const d = emptyData();
  await s.sync(c, d);
  const snip = d.snippets.find((x) => x.name === "from-swift");
  if (!snip || snip.command !== "df -h {{path}}") throw new Error("Swift snippet missing: " + JSON.stringify(d.snippets));
  const host = d.hosts.find((x) => x.id === info.hostID);
  if (!host || host.notes !== "edited on iOS") throw new Error("Swift host edit missing: " + JSON.stringify(host));
  if (d.secrets["pw-" + info.hostID]?.value !== "from-web") throw new Error("password lost in round trip");
  console.log("verified");
}
