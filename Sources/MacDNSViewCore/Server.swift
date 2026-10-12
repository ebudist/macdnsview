import Foundation
import SystemConfiguration

/// A DNS server address. `host` is always an IP literal.
public struct Server: Hashable, Sendable, CustomStringConvertible {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16 = 53) {
        self.host = host
        self.port = port
    }

    public var description: String {
        if port == 53 { return host }
        return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}

public enum ServerError: Error, Equatable {
    case invalidPort(String)
    case unresolvable(String)
}

extension Server {
    /// Parses `1.1.1.1`, `2606:4700::1111`, `host:port`, `[v6]:port`, or a hostname resolved once through the system.
    public init(parsing input: String) throws {
        var host = input.trimmingCharacters(in: .whitespaces)
        var port: UInt16 = 53
        if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
            let rest = host[host.index(after: close)...]
            if rest.hasPrefix(":") { port = try Self.port(String(rest.dropFirst())) }
            host = String(host[host.index(after: host.startIndex) ..< close])
        } else if host.filter({ $0 == ":" }).count == 1, let colon = host.firstIndex(of: ":") {
            port = try Self.port(String(host[host.index(after: colon)...]))
            host = String(host[..<colon])
        }
        if !isIPLiteral(host) {
            guard let resolved = resolveOnce(host) else { throw ServerError.unresolvable(host) }
            host = resolved
        }
        self.init(host: host, port: port)
    }

    private static func port(_ text: String) throws -> UInt16 {
        guard let port = UInt16(text), port > 0 else { throw ServerError.invalidPort(text) }
        return port
    }
}

/// The system's DNS servers: a default list, plus scoped servers that only apply under certain domains.
public struct ResolverConfiguration: Equatable, Sendable {
    public var defaultServers: [Server]
    /// Keyed by match domain, lowercased, without a trailing dot.
    public var scopedServers: [String: [Server]]

    public init(defaultServers: [Server], scopedServers: [String: [Server]] = [:]) {
        self.defaultServers = defaultServers
        self.scopedServers = scopedServers
    }

    /// Servers for a lookup name: the scoped entry with the longest matching suffix, otherwise the default.
    public func servers(for name: String) -> [Server] {
        var labels = name.lowercased().split(separator: ".")
        while !labels.isEmpty {
            if let servers = scopedServers[labels.joined(separator: ".")] { return servers }
            labels.removeFirst()
        }
        return defaultServers
    }

    /// Reads SystemConfiguration (default and VPN supplemental servers) and `/etc/resolver/*`.
    public static func system(resolverDirectory: URL = URL(filePath: "/etc/resolver")) -> ResolverConfiguration {
        var config = ResolverConfiguration(defaultServers: [])
        if let store = SCDynamicStoreCreate(nil, "MacDNSView" as CFString, nil, nil) {
            if let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any] {
                config.defaultServers = servers(global["ServerAddresses"])
            }
            let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/.*/DNS" as CFString) as? [String] ?? []
            for key in keys {
                guard let dns = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                      let domains = dns["SupplementalMatchDomains"] as? [String] else { continue }
                let list = servers(dns["ServerAddresses"])
                for domain in domains.map(normalizedDomain) where !domain.isEmpty && !list.isEmpty {
                    config.scopedServers[domain, default: []].append(contentsOf: list)
                }
            }
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: resolverDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let (domain, list) = parseResolverFile(name: file.lastPathComponent, contents: text)
            if !list.isEmpty { config.scopedServers[domain] = list }
        }
        return config
    }

    private static func servers(_ value: Any?) -> [Server] {
        (value as? [String] ?? []).map { Server(host: $0) }
    }
}

/// Parses one `/etc/resolver` file (see `resolver(5)`): the file name is the domain unless a `domain` line overrides it.
func parseResolverFile(name: String, contents: String) -> (domain: String, servers: [Server]) {
    var domain = name, hosts: [String] = [], port: UInt16 = 53
    for line in contents.split(whereSeparator: \.isNewline) {
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2, !fields[0].hasPrefix("#") else { continue }
        switch fields[0] {
        case "nameserver": hosts.append(String(fields[1]))
        case "port": port = UInt16(fields[1]) ?? port
        case "domain": domain = String(fields[1])
        default: break
        }
    }
    return (normalizedDomain(domain), hosts.map { Server(host: $0, port: port) })
}

private func normalizedDomain(_ domain: String) -> String {
    var d = domain.lowercased()
    if d.hasSuffix(".") { d.removeLast() }
    return d
}

private func isIPLiteral(_ host: String) -> Bool {
    var v4 = in_addr(), v6 = in6_addr()
    let bare = host.split(separator: "%").first.map(String.init) ?? host // fe80::1%en0
    return inet_pton(AF_INET, bare, &v4) == 1 || inet_pton(AF_INET6, bare, &v6) == 1
}

private func resolveOnce(_ host: String) -> String? {
    var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_DGRAM, ai_protocol: 0,
                         ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
    var result: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
    defer { freeaddrinfo(result) }
    var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    guard getnameinfo(first.pointee.ai_addr, first.pointee.ai_addrlen, &buffer, socklen_t(buffer.count),
                      nil, 0, NI_NUMERICHOST) == 0 else { return nil }
    return String(cString: buffer)
}
