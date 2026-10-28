// Subset of TermInput's KeyEncoder for the touch key row. xterm.js handles
// physical keyboards itself.

export type Key = "esc" | "tab" | "up" | "down" | "left" | "right" | "home" | "end" | "pgup" | "pgdn";

export function encodeKey(k: Key, appCursor: boolean): string {
  const cur = (f: string) => (appCursor ? `\x1bO${f}` : `\x1b[${f}`);
  switch (k) {
    case "esc": return "\x1b";
    case "tab": return "\t";
    case "up": return cur("A");
    case "down": return cur("B");
    case "right": return cur("C");
    case "left": return cur("D");
    case "home": return cur("H");
    case "end": return cur("F");
    case "pgup": return "\x1b[5~";
    case "pgdn": return "\x1b[6~";
  }
}

export function ctrl(ch: string): string {
  const c = ch.toLowerCase().charCodeAt(0);
  if (c >= 0x61 && c <= 0x7a) return String.fromCharCode(c - 0x60);
  const map: Record<string, number> = { "@": 0, " ": 0, "[": 0x1b, "\\": 0x1c, "]": 0x1d, "^": 0x1e, "_": 0x1f, "/": 0x1f, "?": 0x7f };
  return ch in map ? String.fromCharCode(map[ch]) : ch;
}
