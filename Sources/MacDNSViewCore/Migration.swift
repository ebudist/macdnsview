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
        public var previous: [String] = []
    }

    public struct Check: Codable, Equatable, Sendable {
        public let target: String
        public let status: MigrationStatus
        public let expected: [String]
        public let answers: [String: [String]]
        public let ttl: UInt32?
        public let error: String?
        public var leftoverAAAA: [String]?
        public var previous: [String]?
    }

    public static func values(_ text: String, kind: Kind) -> [String] {
        let separators: String = kind.isText ? ",\n" : ",; \t\n"
        return text.split(whereSeparator: { separators.contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public static func invalid(_ values: [String], kind: Kind) -> String? {
        switch kind {
        case .record(.a): values.first { IPv4Address($0) == nil && IPv6Address($0) == nil }
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
            let parts = String(line[end...]).split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ",; \t")) }
            func list(_ text: String) -> [String] { kind.isText ? (text.isEmpty ? [] : [text]) : values(text, kind: kind) }
            entries.append(Entry(target: target, expected: list(parts.first ?? ""), previous: list(parts.count > 1 ? parts[1] : "")))
        }
        return entries
    }

    public static func addingWWW(_ entries: [Entry]) -> [Entry] {
        var seen = Set(entries.map(\.target.queryName))
        return entries.flatMap { entry -> [Entry] in
            guard !entry.target.display.hasPrefix("www."), let www = Target("www." + entry.target.display),
                  seen.insert(www.queryName).inserted else { return [entry] }
            return [entry, Entry(target: www, expected: entry.expected, previous: entry.previous)]
        }
    }

    public static func lines(fromCSV text: String) -> String {
        var rows = csvRows(text).filter { !$0.allSatisfy(\.isEmpty) }
        guard let first = rows.first else { return "" }
        let names = first.map { $0.lowercased().replacing(/[^a-z]/, with: "") }
        func column(_ candidates: [String]) -> Int? { names.firstIndex { candidates.contains($0) } }
        var (domain, old, new) = (0, 1, 2)
        if let found = column(["domain", "target", "host", "name"]) {
            domain = found
            old = column(["old", "oldip", "previous", "from", "source"]) ?? -1
            new = column(["new", "newip", "expected", "to", "destination"]) ?? -1
            rows.removeFirst()
        }
        func cell(_ row: [String], _ index: Int) -> String { index >= 0 && index < row.count ? row[index] : "" }
        return rows.map { row in
            let (previous, expected) = (cell(row, old), cell(row, new))
            return cell(row, domain) + (expected.isEmpty && previous.isEmpty ? "" : " " + expected) + (previous.isEmpty ? "" : " | " + previous)
        }
        .joined(separator: "\n")
    }

    static func csvRows(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var characters = text.makeIterator()
        while let c = characters.next() {
            if quoted {
                if c == "\"" {
                    if let next = characters.next() {
                        if next == "\"" { field.append("\"") } else {
                            quoted = false
                            if next == "," { row.append(field); field = "" } else if next.isNewline { row.append(field); rows.append(row); row = []; field = "" } else { field.append(next) }
                        }
                    } else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"", field.isEmpty {
                quoted = true
            } else if c == "," {
                row.append(field.trimmingCharacters(in: .whitespaces))
                field = ""
            } else if c.isNewline {
                row.append(field.trimmingCharacters(in: .whitespaces))
                rows.append(row)
                row = []
                field = ""
            } else {
                field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field.trimmingCharacters(in: .whitespaces)); rows.append(row) }
        return rows
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
        var leftover: [String]?
        if kind == .record(.a) {
            let expectedV6 = Set(new.compactMap { IPv6Address($0)?.rawValue })
            let aaaa = rows.filter { $0.target == target && $0.type == .aaaa && $0.error == nil && $0.section == .answer }.map(\.address)
            let left = Array(Set(aaaa.filter { IPv6Address($0).map { !expectedV6.contains($0.rawValue) } ?? false })).sorted()
            leftover = left.isEmpty ? nil : left
        }
        func result(_ status: MigrationStatus, _ error: String? = nil) -> Check {
            Check(target: target, status: status, expected: new, answers: byServer, ttl: ttl, error: error, leftoverAAAA: leftover,
                  previous: old.isEmpty ? nil : old)
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
