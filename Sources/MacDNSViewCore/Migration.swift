import Foundation
import Network

public enum MigrationStatus: String, CaseIterable, Codable, Sendable {
    case migrated = "Migrated"
    case propagating = "Propagating"
    case pending = "Pending"
    case unexpected = "Unexpected"
    case proxied = "Proxied"
    case failed = "Failed"
}

public enum Migration {
    public struct Entry: Equatable, Sendable {
        public let target: Target
        public let expected: [String]
    }

    public struct Check: Equatable, Sendable {
        public let target: String
        public let status: MigrationStatus
        public let expected: [String]
        public let answers: [String: [String]]
        public let ttl: UInt32?
        public let error: String?
    }

    public static func isAddress(_ text: String) -> Bool {
        IPv4Address(text) != nil || IPv6Address(text) != nil
    }

    public static func addresses(_ text: String) -> [String] {
        text.split(whereSeparator: { ",; \t\n".contains($0) }).map(String.init)
    }

    public static func parse(_ text: String) -> [Entry] {
        var seen = Set<String>()
        var entries: [Entry] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let tokens = line.split(whereSeparator: { ",; \t".contains($0) }).map(String.init)
            guard let first = tokens.first, !first.hasPrefix("#"), let target = Target(first), target.kind == .name,
                  seen.insert(target.queryName).inserted else { continue }
            entries.append(Entry(target: target, expected: tokens.dropFirst().filter(isAddress)))
        }
        return entries
    }

    public static func check(_ target: String, rows: [Row], new: Set<String>, old: Set<String>) -> Check {
        let mine = rows.filter { $0.target == target && $0.type == .a }
        let answers = mine.filter { $0.error == nil && $0.section == .answer && !$0.address.isEmpty }
        var byServer: [String: [String]] = [:]
        for row in answers where !(byServer[row.server]?.contains(row.address) ?? false) { byServer[row.server, default: []].append(row.address) }
        let ttl = answers.compactMap(\.ttl).min()
        let expected = new.sorted()
        func result(_ status: MigrationStatus, _ error: String? = nil) -> Check {
            Check(target: target, status: status, expected: expected, answers: byServer, ttl: ttl, error: error)
        }

        guard !byServer.isEmpty else { return result(.failed, mine.first { $0.error != nil }?.error ?? "no A answer") }
        let all = Set(byServer.values.joined())
        let unknown = all.subtracting(new).subtracting(old)
        if !unknown.isEmpty {
            return unknown.allSatisfy { Cloudflare.range(of: $0) != nil } ? result(.proxied) : result(.unexpected)
        }
        let servers = byServer.values.map(Set.init)
        if servers.allSatisfy({ $0.isSubset(of: new) }) { return result(.migrated) }
        if servers.allSatisfy({ $0.isDisjoint(with: new) }) { return result(.pending) }
        return result(.propagating)
    }
}
