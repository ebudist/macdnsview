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
    public enum Kind: Hashable, Sendable {
        case record(RecordType)
        case dmarc

        public var name: String {
            switch self {
            case .record(let type): type.description
            case .dmarc: "DMARC"
            }
        }

        public var isAddress: Bool { self == .record(.a) || self == .record(.aaaa) }
        public var isHost: Bool { [.record(.cname), .record(.ns), .record(.mx)].contains(self) }
        public var isText: Bool { self == .record(.txt) || self == .dmarc }
    }

    public enum Answer: Sendable {
        case new, old, cloudflare, other
    }

    public struct Entry: Equatable, Sendable {
        public let target: Target
        public let expected: [String]
    }

    public struct Check: Codable, Equatable, Sendable {
        public let target: String
        public let status: MigrationStatus
        public let expected: [String]
        public let answers: [String: [String]]
        public let ttl: UInt32?
        public let error: String?
    }

    public static func values(_ text: String, kind: Kind) -> [String] {
        let separators: String = kind.isText ? ",\n" : ",; \t\n"
        return text.split(whereSeparator: { separators.contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public static func invalid(_ values: [String], kind: Kind) -> String? {
        switch kind {
        case .record(.a): values.first { IPv4Address($0) == nil }
        case .record(.aaaa): values.first { IPv6Address($0) == nil }
        case _ where kind.isHost: values.first { $0.contains(where: \.isWhitespace) || $0.contains("://") }
        default: nil
        }
    }

    public static func parse(_ text: String, kind: Kind) -> [Entry] {
        var seen = Set<String>()
        var entries: [Entry] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            let end = line.firstIndex(where: { ",; \t".contains($0) }) ?? line.endIndex
            let first = String(line[..<end])
            guard !first.hasPrefix("#"), let target = Target(first), target.kind == .name, seen.insert(target.queryName).inserted else { continue }
            let rest = String(line[end...]).trimmingCharacters(in: CharacterSet(charactersIn: ",; \t"))
            entries.append(Entry(target: target, expected: kind.isText ? (rest.isEmpty ? [] : [rest]) : values(rest, kind: kind)))
        }
        return entries
    }

    static func text(_ row: Row, kind: Kind) -> String {
        switch kind {
        case _ where kind.isAddress: row.address
        case _ where kind.isHost: host(row.name)
        case _ where kind.isText: row.data
        default: [row.name, row.data].filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    static func host(_ name: String) -> String {
        name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    static func same(_ answer: String, _ value: String, kind: Kind) -> Bool {
        if kind.isText { return answer.localizedCaseInsensitiveContains(value) }
        if kind.isHost { return answer == host(value) }
        return answer.caseInsensitiveCompare(value) == .orderedSame
    }

    public static func classify(_ answer: String, kind: Kind, new: [String], old: [String]) -> Answer {
        if new.contains(where: { same(answer, $0, kind: kind) }) { return .new }
        if old.contains(where: { same(answer, $0, kind: kind) }) { return .old }
        if kind.isAddress, Cloudflare.range(of: answer) != nil { return .cloudflare }
        return .other
    }

    public static func check(_ target: String, rows: [Row], kind: Kind, new: [String], old: [String]) -> Check {
        let type: RecordType = if case .record(let type) = kind { type } else { .txt }
        let mine = rows.filter { row in
            row.target == target && row.type == type && (kind == .dmarc) == row.name.lowercased().hasPrefix("_dmarc.")
        }
        let answers = mine.filter { $0.error == nil && $0.section == .answer }
        var byServer: [String: [String]] = [:]
        for row in answers {
            let text = text(row, kind: kind)
            if !text.isEmpty, !(byServer[row.server]?.contains(text) ?? false) { byServer[row.server, default: []].append(text) }
        }
        let ttl = answers.compactMap(\.ttl).min()
        func result(_ status: MigrationStatus, _ error: String? = nil) -> Check {
            Check(target: target, status: status, expected: new, answers: byServer, ttl: ttl, error: error)
        }

        guard !byServer.isEmpty else { return result(.failed, mine.first { $0.error != nil }?.error ?? "no \(kind.name) answer") }
        let migrated: ([String]) -> Bool = { answers in
            kind.isText ? new.allSatisfy { value in answers.contains { same($0, value, kind: kind) } }
                : answers.allSatisfy { classify($0, kind: kind, new: new, old: old) == .new }
        }
        let servers = Array(byServer.values)
        if !kind.isText {
            let kinds = Set(servers.joined().map { classify($0, kind: kind, new: new, old: old) })
            if kinds.contains(.other) { return result(.unexpected) }
            if kinds.contains(.cloudflare) { return result(.proxied) }
        }
        if servers.allSatisfy(migrated) { return result(.migrated) }
        if servers.contains(where: migrated) { return result(.propagating) }
        if !kind.isText, servers.allSatisfy({ !$0.contains { classify($0, kind: kind, new: new, old: old) == .new } }) { return result(.pending) }
        return kind.isText ? result(.pending) : result(.propagating)
    }
}
