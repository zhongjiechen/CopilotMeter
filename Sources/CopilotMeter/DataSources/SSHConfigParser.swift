import Foundation

/// Minimal `~/.ssh/config` parser. We only care about extracting the list of
/// declared host aliases so we can present them as toggleable entries in the
/// UI — we don't need to fully implement the resolution rules.
public enum SSHConfigParser {

    /// A discovered host alias plus the IdentityFile (if any) we'd like to
    /// forward to rsync.
    public struct DiscoveredHost: Sendable, Equatable, Identifiable {
        public let name: String
        public let identityFile: String?
        public var id: String { name }
    }

    /// Reads `~/.ssh/config` and returns the list of host aliases declared
    /// there, in declaration order. Wildcard aliases (containing `*` or `?`)
    /// are filtered out — they're not real connectable hosts.
    public static func loadHosts(configPath: String? = nil) -> [DiscoveredHost] {
        let path = configPath ?? "\(NSHomeDirectory())/.ssh/config"
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }

        var hosts: [String] = []
        var identityForHost: [String: String] = [:]
        var lastDeclaredHosts: [String] = []

        for rawLine in content.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            // Split key/value. ssh_config(5) is loose about whitespace and
            // permits "=" as a delimiter, but a simple tokenization covers
            // every config I've seen.
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard let keyPart = parts.first else { continue }
            let key = String(keyPart).lowercased()
            let values = parts.dropFirst().map(String.init)

            if key == "host" {
                lastDeclaredHosts = values.filter { !$0.contains("*") && !$0.contains("?") }
                hosts.append(contentsOf: lastDeclaredHosts)
            } else if key == "identityfile", let value = values.first {
                let expanded = expandTilde(value)
                for h in lastDeclaredHosts {
                    identityForHost[h] = expanded
                }
            }
        }

        // Preserve first-seen order and dedupe.
        var seen: Set<String> = []
        var deduped: [String] = []
        for h in hosts where !seen.contains(h) {
            seen.insert(h)
            deduped.append(h)
        }
        return deduped.map { DiscoveredHost(name: $0, identityFile: identityForHost[$0]) }
    }

    private static func expandTilde(_ s: String) -> String {
        if s.hasPrefix("~/") {
            return "\(NSHomeDirectory())\(s.dropFirst(1))"
        }
        return s
    }
}
