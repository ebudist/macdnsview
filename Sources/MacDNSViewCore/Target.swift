import Foundation

/// One line of user input to look up: a domain name, an IP address, or a URL reduced to its host.
public struct Target: Hashable, Sendable {
    public enum Kind: Sendable { case name, ipv4, ipv6 }

    /// What the user typed, normalized: lowercased host, Unicode kept for IDN.
    public let display: String
    public let kind: Kind
    /// ASCII name for lookups: punycode for IDN, the `in-addr.arpa` or `ip6.arpa` name for addresses.
    public let queryName: String

    /// Splits pasted text or file contents into Targets, dropping duplicates and keeping first-seen order.
    public static func parse(_ text: String, extractHostFromURL: Bool = true) -> [Target] {
        var seen = Set<String>()
        var targets: [Target] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            for token in line.split(whereSeparator: { ",; \t".contains($0) }) {
                guard let target = Target(String(token), extractHostFromURL: extractHostFromURL),
                      seen.insert(target.queryName).inserted else { continue }
                targets.append(target)
            }
        }
        return targets
    }

    init?(_ token: String, extractHostFromURL: Bool = true) {
        var host = token
        if extractHostFromURL {
            if token.contains("://") {
                guard let urlHost = URLComponents(string: token)?.host else { return nil }
                host = urlHost
            } else if let slash = token.firstIndex(of: "/") {
                host = String(token[..<slash])
            }
        }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        host = host.lowercased()
        guard !host.isEmpty else { return nil }

        display = host
        if let reverse = reverseName(ipv4: host) {
            (kind, queryName) = (.ipv4, reverse)
        } else if let reverse = reverseName(ipv6: host) {
            (kind, queryName) = (.ipv6, reverse)
        } else if host.allSatisfy(\.isASCII) {
            (kind, queryName) = (.name, host)
        } else {
            var components = URLComponents()
            components.host = host
            guard let ascii = components.encodedHost else { return nil }
            (kind, queryName) = (.name, ascii)
        }
    }
}

private func reverseName(ipv4: String) -> String? {
    var addr = in_addr()
    guard inet_pton(AF_INET, ipv4, &addr) == 1 else { return nil }
    return withUnsafeBytes(of: addr) { $0.reversed().map(String.init).joined(separator: ".") } + ".in-addr.arpa"
}

private func reverseName(ipv6: String) -> String? {
    var addr = in6_addr()
    guard inet_pton(AF_INET6, ipv6, &addr) == 1 else { return nil }
    let nibbles = withUnsafeBytes(of: addr) { bytes in
        bytes.flatMap { [$0 >> 4, $0 & 0x0F] }
    }
    return nibbles.reversed().map { String($0, radix: 16) }.joined(separator: ".") + ".ip6.arpa"
}
