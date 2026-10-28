import type { ITheme } from "@xterm/xterm";

// Same palettes as ios/Sources/Terminal/Themes.swift.
const make = (bg: string, fg: string, cursor: string, ansi: string[]): ITheme => ({
  background: bg, foreground: fg, cursor, selectionBackground: "#ffffff33",
  black: ansi[0], red: ansi[1], green: ansi[2], yellow: ansi[3], blue: ansi[4], magenta: ansi[5], cyan: ansi[6], white: ansi[7],
  brightBlack: ansi[8], brightRed: ansi[9], brightGreen: ansi[10], brightYellow: ansi[11],
  brightBlue: ansi[12], brightMagenta: ansi[13], brightCyan: ansi[14], brightWhite: ansi[15],
});

export const themes: Record<string, ITheme> = {
  "Conch Dark": make("#14171c", "#d6dae0", "#7fd1ae", ["#1d2128", "#e06c75", "#8cc68f", "#e5c07b", "#6fa8dc", "#c49bd6", "#63c5c9", "#c8ccd2", "#5c6370", "#ff7b85", "#a5dca8", "#f2d08e", "#8bbcf0", "#d8b3e8", "#7fd8db", "#f2f4f7"]),
  "Conch Light": make("#fafafa", "#2b2f36", "#2a7f62", ["#2b2f36", "#c0392b", "#2e7d32", "#9a6a00", "#1f5fa8", "#8e3fa3", "#007c80", "#d0d3d8", "#6b717c", "#e0483a", "#3c9a41", "#b88400", "#2f74c8", "#a857c0", "#00979c", "#ffffff"]),
  "Solarized Dark": make("#002b36", "#839496", "#93a1a1", ["#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#eee8d5", "#002b36", "#cb4b16", "#586e75", "#657b83", "#839496", "#6c71c4", "#93a1a1", "#fdf6e3"]),
  Gruvbox: make("#282828", "#ebdbb2", "#ebdbb2", ["#282828", "#cc241d", "#98971a", "#d79921", "#458588", "#b16286", "#689d6a", "#a89984", "#928374", "#fb4934", "#b8bb26", "#fabd2f", "#83a598", "#d3869b", "#8ec07c", "#ebdbb2"]),
  Nord: make("#2e3440", "#d8dee9", "#d8dee9", ["#3b4252", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#88c0d0", "#e5e9f0", "#4c566a", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#8fbcbb", "#eceff4"]),
  Phosphor: make("#0a0f0a", "#9cf09c", "#9cf09c", ["#0a0f0a", "#5fd75f", "#87ff87", "#afffaf", "#5faf5f", "#87d787", "#afd7af", "#9cf09c", "#3a5a3a", "#87ff87", "#afffaf", "#d7ffd7", "#87d787", "#afd7af", "#d7ffd7", "#eaffea"]),
};
