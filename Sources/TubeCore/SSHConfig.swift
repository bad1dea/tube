import Foundation

/// Subset of ssh_config(5) that maps onto Host records: Host, HostName, User,
/// Port, IdentityFile, ProxyJump. Wildcard Host blocks are kept as defaults and
/// applied to the concrete aliases that follow OpenSSH's first-match rule.
public struct SSHConfigEntry: Hashable, Sendable {
    public var alias: String
    public var hostname: String
    public var user: String?
    public var port: Int?
    public var identityFile: String?
    /// Raw ProxyJump value split on commas.
    public var proxyJump: [String]

    public init(alias: String, hostname: String, user: String? = nil, port: Int? = nil,
                identityFile: String? = nil, proxyJump: [String] = []) {
        self.alias = alias
        self.hostname = hostname
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.proxyJump = proxyJump
    }
}

public struct JumpSpec: Hashable, Sendable {
    public var user: String?
    public var host: String
    public var port: Int?

    /// Parses `[user@]host[:port]`, including `[v6]:port`.
    public init?(_ s: String) {
        var rest = Substring(s.trimmingCharacters(in: .whitespaces))
        if rest.isEmpty || rest == "none" { return nil }
        if rest.hasPrefix("ssh://") { rest = rest.dropFirst(6) }
        if let at = rest.lastIndex(of: "@") {
            user = String(rest[..<at])
            rest = rest[rest.index(after: at)...]
        }
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            host = String(rest[rest.index(after: rest.startIndex)..<close])
            let after = rest[rest.index(after: close)...]
            if after.hasPrefix(":") { port = Int(after.dropFirst()) }
        } else if let colon = rest.lastIndex(of: ":"), rest.firstIndex(of: ":") == colon {
            host = String(rest[..<colon])
            port = Int(rest[rest.index(after: colon)...])
        } else {
            host = String(rest)
        }
        if host.isEmpty { return nil }
    }
}

public enum SSHConfig {
    public static func parse(_ text: String) -> [SSHConfigEntry] {
        struct Block { var patterns: [String]; var options: [(String, String)] }
        var blocks: [Block] = []
        var current: Block? = nil

        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let (key, value) = splitOption(line) else { continue }
            let k = key.lowercased()
            if k == "host" {
                if let c = current { blocks.append(c) }
                current = Block(patterns: value.split(separator: " ").map(String.init), options: [])
            } else if k == "match" {
                // Match blocks depend on runtime state we do not have; skip them.
                if let c = current { blocks.append(c) }
                current = Block(patterns: [], options: [])
            } else {
                if current == nil { current = Block(patterns: ["*"], options: []) }
                current?.options.append((k, value))
            }
        }
        if let c = current { blocks.append(c) }

        var entries: [SSHConfigEntry] = []
        let aliases = blocks.flatMap { $0.patterns }.filter { !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") }
        var seen = Set<String>()
        for alias in aliases where seen.insert(alias).inserted {
            var opts: [String: String] = [:]
            for block in blocks where matches(alias, block.patterns) {
                for (k, v) in block.options where opts[k] == nil { opts[k] = v }
            }
            entries.append(SSHConfigEntry(
                alias: alias,
                hostname: opts["hostname"] ?? alias,
                user: opts["user"],
                port: opts["port"].flatMap(Int.init),
                identityFile: opts["identityfile"],
                proxyJump: opts["proxyjump"].map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } } ?? []
            ))
        }
        return entries
    }

    static func splitOption(_ line: String) -> (String, String)? {
        // "Key value", "Key=value" and "Key = value" are all valid.
        guard let sep = line.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else { return nil }
        let key = String(line[..<sep])
        var value = line[sep...].drop(while: { $0 == " " || $0 == "\t" })
        if value.hasPrefix("=") { value = value.dropFirst().drop(while: { $0 == " " || $0 == "\t" }) }
        var v = String(value)
        if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 { v = String(v.dropFirst().dropLast()) }
        return (key, v)
    }

    static func matches(_ alias: String, _ patterns: [String]) -> Bool {
        var matched = false
        for p in patterns {
            if p.hasPrefix("!") {
                if glob(String(p.dropFirst()), alias) { return false }
            } else if glob(p, alias) {
                matched = true
            }
        }
        return matched
    }

    static func glob(_ pattern: String, _ s: String) -> Bool {
        let p = Array(pattern), t = Array(s)
        var pi = 0, ti = 0, star = -1, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "?" || p[pi] == t[ti] {
                pi += 1; ti += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi; mark = ti; pi += 1
            } else if star >= 0 {
                pi = star + 1; mark += 1; ti = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    /// Converts parsed entries into hosts. Jump hosts that refer to another alias
    /// link to that host; literal `user@host:port` hops become new hosts.
    public static func importHosts(_ entries: [SSHConfigEntry], defaultUser: String) -> [Host] {
        var byAlias: [String: Host] = [:]
        var order: [String] = []
        for e in entries {
            byAlias[e.alias] = Host(label: e.alias, hostname: e.hostname, port: e.port ?? 22,
                                    username: e.user ?? defaultUser)
            order.append(e.alias)
        }
        var extra: [Host] = []
        for e in entries where !e.proxyJump.isEmpty {
            var ids: [UUID] = []
            for hop in e.proxyJump {
                guard let spec = JumpSpec(hop) else { continue }
                if var known = byAlias[spec.host] {
                    if spec.user != nil || spec.port != nil {
                        known.id = UUID()
                        known.username = spec.user ?? known.username
                        known.port = spec.port ?? known.port
                        extra.append(known)
                    }
                    ids.append(known.id)
                } else if let existing = extra.first(where: {
                    $0.hostname == spec.host && $0.port == (spec.port ?? 22) && $0.username == (spec.user ?? defaultUser)
                }) {
                    ids.append(existing.id)
                } else {
                    let h = Host(label: spec.host, hostname: spec.host, port: spec.port ?? 22,
                                 username: spec.user ?? defaultUser)
                    extra.append(h)
                    ids.append(h.id)
                }
            }
            byAlias[e.alias]?.jumpHostIDs = ids
        }
        return order.compactMap { byAlias[$0] } + extra
    }

    public static func export(_ hosts: [Host], identityFile: (UUID) -> String? = { _ in nil }) -> String {
        let byID = Dictionary(uniqueKeysWithValues: hosts.map { ($0.id, $0) })
        var aliases: [UUID: String] = [:]
        var used = Set<String>()
        for h in hosts {
            var base = h.displayName.replacingOccurrences(of: " ", with: "-")
            if base.isEmpty { base = h.hostname }
            var a = base, n = 2
            while !used.insert(a).inserted { a = "\(base)-\(n)"; n += 1 }
            aliases[h.id] = a
        }
        var out = ""
        for h in hosts {
            out += "Host \(aliases[h.id]!)\n"
            out += "    HostName \(h.hostname)\n"
            out += "    User \(h.username)\n"
            if h.port != 22 { out += "    Port \(h.port)\n" }
            if let id = h.identityID, let path = identityFile(id) { out += "    IdentityFile \(path)\n" }
            let jumps = h.jumpHostIDs.compactMap { byID[$0].map { aliases[$0.id]! } }
            if !jumps.isEmpty { out += "    ProxyJump \(jumps.joined(separator: ","))\n" }
            out += "\n"
        }
        return out
    }
}

public enum QuickConnect {
    /// Accepts "host", "user@host", "user@host:port", "[v6]:port" and
    /// "ssh [-p port] [-l user] user@host" as typed into the quick connect field.
    public static func parse(_ input: String) -> (user: String?, host: String, port: Int?)? {
        var words = input.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.first == "ssh" { words.removeFirst() }
        var port: Int?
        var user: String?
        var target: String?
        var i = 0
        while i < words.count {
            let w = words[i]
            if (w == "-p" || w == "-l"), i + 1 < words.count {
                if w == "-p" { port = Int(words[i + 1]) } else { user = words[i + 1] }
                i += 2
                continue
            }
            if w.hasPrefix("-") { i += 1; continue }
            target = w
            i += 1
        }
        guard let target, let spec = JumpSpec(target) else { return nil }
        return (spec.user ?? user, spec.host, spec.port ?? port)
    }
}
