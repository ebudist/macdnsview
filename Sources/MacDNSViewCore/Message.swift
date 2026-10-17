import Foundation

public struct RecordType: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt16
    public init(_ rawValue: UInt16) { self.rawValue = rawValue }

    public static let a = RecordType(1)
    public static let ns = RecordType(2)
    public static let cname = RecordType(5)
    public static let soa = RecordType(6)
    public static let ptr = RecordType(12)
    public static let mx = RecordType(15)
    public static let txt = RecordType(16)
    public static let aaaa = RecordType(28)
    public static let srv = RecordType(33)
    public static let ds = RecordType(43)
    public static let dnskey = RecordType(48)
    public static let svcb = RecordType(64)
    public static let https = RecordType(65)
    public static let caa = RecordType(257)

    private static let names: [UInt16: String] = [
        1: "A", 2: "NS", 5: "CNAME", 6: "SOA", 12: "PTR", 15: "MX",
        16: "TXT", 28: "AAAA", 33: "SRV", 43: "DS", 48: "DNSKEY", 64: "SVCB", 65: "HTTPS", 257: "CAA",
    ]

    public var description: String { Self.names[rawValue] ?? "TYPE\(rawValue)" }
}

public enum Section: String, Codable, Sendable {
    case answer = "Answer"
    case authority = "Authority"
    case additional = "Additional"
}

public enum RecordData: Equatable, Sendable {
    case a(String)
    case aaaa(String)
    case cname(String)
    case ns(String)
    case ptr(String)
    case mx(preference: UInt16, exchange: String)
    case soa(primary: String, admin: String, serial: UInt32, refresh: UInt32, retry: UInt32, expire: UInt32, minimum: UInt32)
    case srv(priority: UInt16, weight: UInt16, port: UInt16, target: String)
    case txt([String])
    case caa(flags: UInt8, tag: String, value: String)
    /// Also used for HTTPS, which shares the format.
    case svcb(priority: UInt16, target: String, params: String)
    case ds(keyTag: UInt16, algorithm: UInt8, digestType: UInt8, digest: [UInt8])
    case dnskey(flags: UInt16, protocol: UInt8, algorithm: UInt8, key: [UInt8])
    case unknown([UInt8])
}

public struct Record: Equatable, Sendable {
    public let name: String
    public let type: RecordType
    public let ttl: UInt32
    public let section: Section
    public let data: RecordData
}

public enum ResponseCode: Equatable, Sendable, CustomStringConvertible {
    case noError, formErr, servFail, nxDomain, notImp, refused
    case other(UInt8)

    init(_ code: UInt8) {
        switch code {
        case 0: self = .noError
        case 1: self = .formErr
        case 2: self = .servFail
        case 3: self = .nxDomain
        case 4: self = .notImp
        case 5: self = .refused
        default: self = .other(code)
        }
    }

    public var description: String {
        switch self {
        case .noError: "NOERROR"
        case .formErr: "FORMERR"
        case .servFail: "SERVFAIL"
        case .nxDomain: "NXDOMAIN"
        case .notImp: "NOTIMP"
        case .refused: "REFUSED"
        case .other(let code): "RCODE\(code)"
        }
    }
}

public enum MessageError: Error, Equatable {
    case truncated
    case invalidName(String)
    case badCompressionPointer(offset: Int)
    case badRecordData(RecordType)
}

/// A decoded DNS response.
public struct Message: Equatable, Sendable {
    public let id: UInt16
    public let isTruncated: Bool
    /// The AD bit.
    public var isAuthenticated = false
    public let responseCode: ResponseCode
    public let questionName: String
    public let questionType: RecordType
    public let records: [Record]

    /// Builds a recursive query for one name and type. `name` must already be ASCII (punycode for IDN).
    public static func query(id: UInt16 = .random(in: 0 ... .max), name: String, type: RecordType) throws -> Data {
        var bytes: [UInt8] = []
        bytes.append16(id)
        bytes.append16(0x0120) // RD and AD (RFC 6840)
        bytes.append16(1)
        bytes.append16(0)
        bytes.append16(0)
        bytes.append16(0)
        try bytes.appendName(name)
        bytes.append16(type.rawValue)
        bytes.append16(1) // IN
        return Data(bytes)
    }
}

extension Message {
    public init(decoding data: Data) throws {
        var r = Reader(Array(data))
        id = try r.u16()
        let flags = try r.u16()
        isTruncated = flags & 0x0200 != 0
        isAuthenticated = flags & 0x0020 != 0
        responseCode = ResponseCode(UInt8(flags & 0x000F))
        let qd = try r.u16(), an = try r.u16(), ns = try r.u16(), ar = try r.u16()

        var questionName = "", questionType = RecordType(0)
        for i in 0 ..< qd {
            let name = try r.name()
            let type = RecordType(try r.u16())
            _ = try r.u16()
            if i == 0 { (questionName, questionType) = (name, type) }
        }
        self.questionName = questionName
        self.questionType = questionType

        var records: [Record] = []
        for (count, section) in [(an, Section.answer), (ns, .authority), (ar, .additional)] {
            for _ in 0 ..< count { records.append(try r.record(section)) }
        }
        self.records = records
    }
}

private struct Reader {
    let bytes: [UInt8]
    var pos = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func u8() throws -> UInt8 {
        guard pos < bytes.count else { throw MessageError.truncated }
        defer { pos += 1 }
        return bytes[pos]
    }

    mutating func u16() throws -> UInt16 { UInt16(try u8()) << 8 | UInt16(try u8()) }

    mutating func u32() throws -> UInt32 { UInt32(try u16()) << 16 | UInt32(try u16()) }

    mutating func take(_ n: Int) throws -> [UInt8] {
        guard n >= 0, pos + n <= bytes.count else { throw MessageError.truncated }
        defer { pos += n }
        return Array(bytes[pos ..< pos + n])
    }

    /// Reads a possibly compressed name. Pointers must point strictly backwards, which rules out loops.
    mutating func name() throws -> String {
        var labels: [String] = []
        var cursor = pos
        var resumeAt: Int?
        var length = 0
        while true {
            guard cursor < bytes.count else { throw MessageError.truncated }
            let len = Int(bytes[cursor])
            switch len & 0xC0 {
            case 0x00:
                if len == 0 {
                    pos = resumeAt ?? cursor + 1
                    return labels.isEmpty ? "." : labels.joined(separator: ".")
                }
                guard cursor + 1 + len <= bytes.count else { throw MessageError.truncated }
                length += len + 1
                guard length <= 255 else { throw MessageError.invalidName("longer than 255 bytes") }
                labels.append(String(decoding: bytes[cursor + 1 ... cursor + len], as: UTF8.self))
                cursor += 1 + len
            case 0xC0:
                guard cursor + 1 < bytes.count else { throw MessageError.truncated }
                let target = (len & 0x3F) << 8 | Int(bytes[cursor + 1])
                guard target < cursor else { throw MessageError.badCompressionPointer(offset: cursor) }
                if resumeAt == nil { resumeAt = cursor + 2 }
                cursor = target
            default:
                throw MessageError.invalidName("unsupported label type at offset \(cursor)")
            }
        }
    }

    mutating func record(_ section: Section) throws -> Record {
        let name = try name()
        let type = RecordType(try u16())
        _ = try u16() // class
        let ttl = try u32()
        let length = Int(try u16())
        let end = pos + length
        guard end <= bytes.count else { throw MessageError.truncated }
        let data = try recordData(type, end: end)
        guard pos == end else { throw MessageError.badRecordData(type) }
        return Record(name: name, type: type, ttl: ttl, section: section, data: data)
    }

    private mutating func recordData(_ type: RecordType, end: Int) throws -> RecordData {
        switch type {
        case .a:
            guard end - pos == 4 else { throw MessageError.badRecordData(type) }
            return .a(try take(4).map(String.init).joined(separator: "."))
        case .aaaa:
            guard end - pos == 16 else { throw MessageError.badRecordData(type) }
            return .aaaa(ipv6String(try take(16)))
        case .cname: return .cname(try name())
        case .ns: return .ns(try name())
        case .ptr: return .ptr(try name())
        case .mx: return .mx(preference: try u16(), exchange: try name())
        case .soa:
            return .soa(primary: try name(), admin: try name(), serial: try u32(),
                        refresh: try u32(), retry: try u32(), expire: try u32(), minimum: try u32())
        case .srv:
            return .srv(priority: try u16(), weight: try u16(), port: try u16(), target: try name())
        case .txt:
            var strings: [String] = []
            while pos < end {
                let n = Int(try u8())
                guard pos + n <= end else { throw MessageError.badRecordData(type) }
                strings.append(String(decoding: try take(n), as: UTF8.self))
            }
            return .txt(strings)
        case .caa:
            let flags = try u8()
            let tagLength = Int(try u8())
            guard pos + tagLength <= end else { throw MessageError.badRecordData(type) }
            let tag = String(decoding: try take(tagLength), as: UTF8.self)
            return .caa(flags: flags, tag: tag, value: String(decoding: try take(end - pos), as: UTF8.self))
        case .svcb, .https:
            let priority = try u16(), target = try name()
            var params: [String] = []
            while pos < end {
                let key = try u16(), length = Int(try u16())
                guard pos + length <= end else { throw MessageError.badRecordData(type) }
                params.append(svcParam(key, try take(length)))
            }
            return .svcb(priority: priority, target: target, params: params.joined(separator: " "))
        case .ds:
            return .ds(keyTag: try u16(), algorithm: try u8(), digestType: try u8(), digest: try take(end - pos))
        case .dnskey:
            return .dnskey(flags: try u16(), protocol: try u8(), algorithm: try u8(), key: try take(end - pos))
        default:
            return .unknown(try take(end - pos))
        }
    }
}

/// RFC 9460 presentation form.
private func svcParam(_ key: UInt16, _ v: [UInt8]) -> String {
    let names: [UInt16: String] = [0: "mandatory", 1: "alpn", 2: "no-default-alpn", 3: "port", 4: "ipv4hint", 5: "ech", 6: "ipv6hint", 7: "dohpath"]
    let name = names[key] ?? "key\(key)"
    func chunks(_ n: Int) -> [[UInt8]] { stride(from: 0, to: v.count, by: n).map { Array(v[$0 ..< $0 + n]) } }
    let value: String? = switch key {
    case 0 where v.count % 2 == 0: chunks(2).map { names[UInt16($0[0]) << 8 | UInt16($0[1])] ?? "key\(UInt16($0[0]) << 8 | UInt16($0[1]))" }.joined(separator: ",")
    case 1: alpnIDs(v)?.joined(separator: ",")
    case 2 where v.isEmpty: nil
    case 3 where v.count == 2: String(UInt16(v[0]) << 8 | UInt16(v[1]))
    case 4 where v.count % 4 == 0 && !v.isEmpty: chunks(4).map { $0.map(String.init).joined(separator: ".") }.joined(separator: ",")
    case 5: "(\(v.count) bytes)"
    case 6 where v.count % 16 == 0 && !v.isEmpty: chunks(16).map(ipv6String).joined(separator: ",")
    case 7: String(decoding: v, as: UTF8.self)
    default: v.map { String(format: "%02x", $0) }.joined()
    }
    return value.map { "\(name)=\($0)" } ?? name
}

private func alpnIDs(_ v: [UInt8]) -> [String]? {
    var ids: [String] = [], i = 0
    while i < v.count {
        let n = Int(v[i])
        guard i + 1 + n <= v.count else { return nil }
        ids.append(String(decoding: v[i + 1 ..< i + 1 + n], as: UTF8.self))
        i += 1 + n
    }
    return ids
}

/// RFC 5952 text form: lowercase, longest run of two or more zero groups collapsed to "::".
private func ipv6String(_ b: [UInt8]) -> String {
    let groups = (0 ..< 8).map { UInt16(b[$0 * 2]) << 8 | UInt16(b[$0 * 2 + 1]) }
    var best = (start: -1, len: 0), run = (start: -1, len: 0)
    for (i, g) in groups.enumerated() {
        if g == 0 {
            run = run.start < 0 ? (i, 1) : (run.start, run.len + 1)
            if run.len > best.len { best = run }
        } else {
            run = (-1, 0)
        }
    }
    let hex = groups.map { String($0, radix: 16) }
    guard best.len >= 2 else { return hex.joined(separator: ":") }
    let head = hex[..<best.start].joined(separator: ":")
    let tail = hex[(best.start + best.len)...].joined(separator: ":")
    return head + "::" + tail
}

private extension [UInt8] {
    mutating func append16(_ v: UInt16) { append(contentsOf: [UInt8(v >> 8), UInt8(v & 0xFF)]) }

    mutating func appendName(_ name: String) throws {
        let trimmed = name.hasSuffix(".") ? String(name.dropLast()) : name
        guard !trimmed.isEmpty else { return append(0) }
        var total = 1
        for label in trimmed.split(separator: ".", omittingEmptySubsequences: false) {
            let bytes = Array(label.utf8)
            guard !bytes.isEmpty else { throw MessageError.invalidName("empty label in \(name)") }
            guard bytes.count <= 63 else { throw MessageError.invalidName("label longer than 63 bytes in \(name)") }
            guard bytes.allSatisfy({ $0 < 0x80 }) else { throw MessageError.invalidName("non-ASCII \(name), convert to punycode first") }
            total += bytes.count + 1
            guard total <= 255 else { throw MessageError.invalidName("longer than 255 bytes: \(name)") }
            append(UInt8(bytes.count))
            append(contentsOf: bytes)
        }
        append(0)
    }
}
