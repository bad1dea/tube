import Foundation

/// Follows what the user is typing on the current shell line from the bytes
/// the app sends. It only knows printable input and simple editing; anything
/// it cannot model (arrows, history recall, Tab completion by the shell)
/// marks the line unknown until the next Return, so suggestions never act on
/// a guess about what is on screen.
public struct LineTracker: Equatable, Sendable {
    public private(set) var text = ""
    public private(set) var known = true

    public init() {}

    /// Returns the finished line when the bytes include Return and the line
    /// was fully tracked.
    public mutating func feed(_ bytes: [UInt8]) -> String? {
        var finished: String?
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            switch b {
            case 0x0d, 0x0a:
                if known && !text.isEmpty { finished = text }
                reset()
            case 0x03, 0x04, 0x15:          // ^C ^D ^U clear the line
                reset()
            case 0x7f, 0x08:
                if !text.isEmpty { text.removeLast() }
            case 0x17:                      // ^W word delete
                while text.last == " " { text.removeLast() }
                while let c = text.last, c != " " { text.removeLast() }
            case 0x1b, 0x09, 0x01, 0x05, 0x0b, 0x12:
                // ESC sequences, Tab completion, ^A ^E ^K ^R: the shell's line
                // no longer matches what we can see from here.
                known = false
                text = ""
                if b == 0x1b { i = bytes.count }
            case 0x20...0x7e:
                text.append(Character(UnicodeScalar(b)))
            default:
                if b >= 0x80 {
                    // UTF-8 continuation of a printable character.
                    var end = i + 1
                    while end < bytes.count, bytes[end] & 0xc0 == 0x80 { end += 1 }
                    text += String(decoding: bytes[i..<end], as: UTF8.self)
                    i = end
                    continue
                }
                known = false
            }
            i += 1
        }
        return finished
    }

    public mutating func reset() {
        text = ""
        known = true
    }
}

/// Command suggestions from the user's own history plus a short list of
/// common commands. History wins: frequency and recency both count.
public struct CommandSuggester: Sendable {
    public struct Entry: Codable, Hashable, Sendable {
        public var command: String
        public var count: Int
        public var lastUsed: Date
        public init(command: String, count: Int = 1, lastUsed: Date = Date()) {
            self.command = command
            self.count = count
            self.lastUsed = lastUsed
        }
    }

    public static let common: [String] = [
        "ls -la", "cd ..", "cd ~", "pwd", "cat ", "less ", "tail -f ", "grep -rn ", "find . -name ",
        "df -h", "du -sh *", "free -h", "uptime", "top", "htop", "ps aux | grep ",
        "sudo ", "sudo systemctl status ", "sudo systemctl restart ", "journalctl -fu ", "journalctl -xe",
        "ip a", "ss -tlnp", "ping ", "curl -I ", "dig ",
        "git status", "git pull", "git log --oneline -n 20", "git diff",
        "docker ps", "docker compose up -d", "docker compose logs -f", "docker logs -f ",
        "tmux attach", "tmux new -s ", "vim ", "nano ", "exit",
    ]

    public var history: [Entry]

    public init(history: [Entry] = []) { self.history = history }

    public mutating func record(_ command: String, at date: Date = Date()) {
        let c = command.trimmingCharacters(in: .whitespaces)
        guard c.count >= 2 else { return }
        if let i = history.firstIndex(where: { $0.command == c }) {
            history[i].count += 1
            history[i].lastUsed = date
        } else {
            history.append(Entry(command: c, lastUsed: date))
        }
        if history.count > 500 {
            var kept = history
            kept.sort { score($0, now: date) > score($1, now: date) }
            history = Array(kept.prefix(500))
        }
    }

    func score(_ e: Entry, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(e.lastUsed) / 86_400)
        return Double(e.count) / (1 + days / 7)
    }

    /// Up to `limit` full commands that extend `prefix`, best first. Empty
    /// prefix gives nothing: suggestions follow typing, they do not lead it.
    public func suggestions(for prefix: String, limit: Int = 6, now: Date = Date()) -> [String] {
        let p = prefix
        guard !p.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        var out: [String] = []
        let fromHistory = history
            .filter { $0.command.hasPrefix(p) && $0.command != p }
            .sorted { score($0, now: now) > score($1, now: now) }
            .map(\.command)
        for c in fromHistory where !out.contains(c) { out.append(c) }
        for c in Self.common where c.hasPrefix(p) && c != p && !out.contains(c) { out.append(c) }
        return Array(out.prefix(limit))
    }
}
