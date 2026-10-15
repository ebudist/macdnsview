import Foundation

/// The record types and follow-up rules chosen for a run. Defaults match DNSDataView.
public struct LookupOptions: Codable, Equatable, Sendable {
    /// Queried in `RecordType.lookupOrder`, whatever order they are listed in.
    public var types: Set<RecordType> = [.ns, .mx, .a, .cname, .soa, .txt]
    /// TXT lookup on `_dmarc.<target>`.
    public var dmarc = false
    public var ptrForEveryAddress = false
    public var aForEveryPTRHost = false
    public var reverseLookupAddresses = true
    public var showErrors = true
    public var hideAdditional = false
    public var extractHostFromURL = true

    public init() {}
}

extension RecordType: Codable {
    public init(from decoder: Decoder) throws { self.init(try decoder.singleValueContainer().decode(UInt16.self)) }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension RecordType {
    public static let lookupOrder: [RecordType] = [.ns, .mx, .a, .aaaa, .cname, .soa, .srv, .txt, .caa, .https, .svcb, .ds, .dnskey]
}

/// One Record or Error row, shaped for the results table.
public struct Row: Equatable, Identifiable, Sendable {
    public var index: Int
    public let target: String
    public let type: RecordType
    public let name: String
    public let address: String
    public let data: String
    public let section: Section?
    public let ttl: UInt32?
    public let server: String
    /// `NXDOMAIN`, `NODATA`, `timeout`, and so on. Nil for a Record.
    public let error: String?
    /// Milliseconds, retries included.
    public var time: Int? = nil
    public var validated: Bool? = nil
    public var differs: Bool? = nil
    /// Position in canonical order: Target, query, Server, Record.
    let order: [Int]

    public var id: Int { index }

    /// An Error row that counts as a failed lookup. NODATA is an answer, not a failure.
    public var isFailure: Bool { error != nil && error != "NODATA" }
}

public typealias QueryFunction = @Sendable (_ name: String, _ type: RecordType, _ server: Server) async throws -> Message

public struct Lookup: Sendable {
    public var options: LookupOptions
    public var servers: [Server]
    public var maxConcurrent = 16
    var resolvers: @Sendable () -> ResolverConfiguration = { .system() }
    var query: QueryFunction

    public init(options: LookupOptions = LookupOptions(), servers: [Server] = [], transport: Transport = Transport()) {
        self.options = options
        self.servers = servers
        query = { try await transport.query($0, type: $1, server: $2) }
    }

    /// All rows in canonical order (Target input order, then query order), indexed from 1.
    public func run(_ targets: [Target]) async -> [Row] {
        var rows: [Row] = []
        for await row in stream(targets) { rows.append(row) }
        return Lookup.canonical(rows)
    }

    /// Streamed rows put back in canonical order, without duplicates, indexed from 1.
    /// Deduplicating after sorting keeps the canonical first copy, whichever answer arrived first.
    public static func canonical(_ rows: [Row]) -> [Row] {
        var seen = Set<[String]>()
        var rows = rows.sorted { $0.order.lexicographicallyPrecedes($1.order) }.filter { row in
            seen.insert([row.target, row.type.description, row.name, row.address, row.data, row.section?.rawValue ?? "", row.error ?? "", row.server]).inserted
        }
        for i in rows.indices { rows[i].index = i + 1 }
        markDifferences(&rows)
        return rows
    }

    private static func markDifferences(_ rows: inout [Row]) {
        for group in Dictionary(grouping: rows.indices, by: { rows[$0].order.prefix(2) }).values {
            let byServer = Dictionary(grouping: group, by: { rows[$0].server })
            guard byServer.count > 1 else { continue }
            let answers = byServer.mapValues { indices in
                Set(indices.map { rows[$0] }.filter { $0.section == .answer || $0.error != nil }
                    .map { [$0.type.description, $0.name, $0.address, $0.data, $0.error ?? ""] })
            }
            let counts = Dictionary(answers.values.map { ($0, 1) }, uniquingKeysWith: +)
            let top = counts.values.max() ?? 0
            let agreed = counts.filter { $0.value == top }.count == 1 ? counts.first { $0.value == top }?.key : nil
            for (server, indices) in byServer {
                for i in indices { rows[i].differs = answers[server] != agreed }
            }
        }
    }

    /// Rows as answers arrive, indexed in arrival order. Duplicates are left in; `canonical` removes them.
    public func stream(_ targets: [Target]) -> AsyncStream<Row> {
        AsyncStream { continuation in
            let task = Task {
                await execute(targets) { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct Job: Sendable {
        let target: Int
        let name: String
        let type: RecordType
        /// Address being reversed, shown in the Address column of PTR rows.
        let address: String?
        let hop: Int
        var order: [Int]
        var server: Server? = nil
    }

    private func execute(_ targets: [Target], emit: (Row) -> Void) async {
        let config = servers.isEmpty ? resolvers() : ResolverConfiguration(defaultServers: [])
        let choices: [Server?] = servers.isEmpty ? [nil] : servers
        var pending = targets.indices.flatMap { initialJobs(for: targets[$0], at: $0) }.flatMap { job in
            choices.enumerated().map { i, server in
                var job = job
                job.order.insert(i, at: 2)
                job.server = server
                return job
            }
        }[...]
        var index = 0
        var running = 0

        await withTaskGroup(of: (Job, Server?, Result<Message, Error>, Int?).self) { group in
            func startNext() {
                guard let job = pending.popFirst() else { return }
                running += 1
                let server = job.server ?? config.servers(for: job.name).first
                group.addTask {
                    guard let server else { return (job, nil, .failure(LookupError.noServer), nil) }
                    let start = ContinuousClock.now
                    func elapsed() -> Int { Int((ContinuousClock.now - start) / .milliseconds(1)) }
                    do {
                        // An await inside the tuple loses `server` in release builds from Swift 6.4 Command Line Tools.
                        let message = try await query(job.name, job.type, server)
                        return (job, server, .success(message), elapsed())
                    } catch { return (job, server, .failure(error), elapsed()) }
                }
            }
            func refill() { while running < maxConcurrent, !pending.isEmpty { startNext() } }
            refill()

            for await (job, server, result, time) in group {
                running -= 1
                let (rows, followUps) = interpret(job, server: server, result: result, targets: targets)
                pending.append(contentsOf: followUps)
                for row in rows {
                    index += 1
                    var row = row
                    row.index = index
                    row.time = time
                    if case .success(let message) = result { row.validated = message.isAuthenticated }
                    emit(row)
                }
                refill()
            }
        }
    }

    private func initialJobs(for target: Target, at position: Int) -> [Job] {
        if target.kind != .name, options.reverseLookupAddresses {
            return [Job(target: position, name: target.queryName, type: .ptr, address: target.display, hop: 0, order: [position, 0])]
        }
        let name = target.kind == .name ? target.queryName : target.display
        var jobs = RecordType.lookupOrder.enumerated()
            .filter { options.types.contains($0.element) }
            .map { Job(target: position, name: name, type: $0.element, address: nil, hop: 0, order: [position, $0.offset]) }
        if options.dmarc {
            jobs.append(Job(target: position, name: "_dmarc." + name, type: .txt, address: nil, hop: 0,
                            order: [position, RecordType.lookupOrder.count]))
        }
        return jobs
    }

    private func interpret(_ job: Job, server: Server?, result: Result<Message, Error>, targets: [Target]) -> ([Row], [Job]) {
        let target = targets[job.target].display
        let serverText = server?.description ?? ""
        func errorRow(_ code: String) -> Row {
            Row(index: 0, target: target, type: job.type, name: job.name, address: job.address ?? "", data: code,
                section: nil, ttl: nil, server: serverText, error: code, order: job.order + [0])
        }

        let message: Message
        switch result {
        case .failure(let error):
            return (options.showErrors ? [errorRow(errorCode(error))] : [], [])
        case .success(let m):
            message = m
        }
        let answers = message.records.filter { $0.section == .answer }
        guard message.responseCode == .noError, !answers.isEmpty else {
            let code = message.responseCode == .noError ? "NODATA" : message.responseCode.description
            return (options.showErrors ? [errorRow(code)] : [], [])
        }

        var rows: [Row] = []
        var followUps: [Job] = []
        for (i, record) in message.records.enumerated() {
            if options.hideAdditional, record.section == .additional { continue }
            let (name, address, data) = columns(record, reversed: job.address)
            rows.append(Row(index: 0, target: target, type: record.type, name: name, address: address, data: data,
                            section: record.section, ttl: record.ttl, server: serverText, error: nil, order: job.order + [i]))
            guard job.hop == 0, record.section == .answer else { continue }
            let next = job.order + [i, 1]
            switch record.data {
            case .a(let ip) where options.ptrForEveryAddress, .aaaa(let ip) where options.ptrForEveryAddress:
                if let reverse = Target.parse(ip).first, reverse.kind != .name {
                    followUps.append(Job(target: job.target, name: reverse.queryName, type: .ptr, address: ip, hop: 1, order: next, server: job.server))
                }
            case .ptr(let host) where options.aForEveryPTRHost:
                followUps.append(Job(target: job.target, name: host, type: .a, address: nil, hop: 1, order: next, server: job.server))
            default:
                break
            }
        }
        return (rows, followUps)
    }
}

public enum LookupError: Error, CustomStringConvertible {
    case noServer
    public var description: String { "no DNS server" }
}

private func errorCode(_ error: Error) -> String {
    switch error {
    case let error as TransportError: error.description
    case let error as LookupError: error.description
    case is MessageError: "invalid name or response"
    default: String(describing: error)
    }
}

/// Name, Address, and Data columns for one Record. `reversed` is the address a PTR query was made for.
private func columns(_ record: Record, reversed: String?) -> (String, String, String) {
    switch record.data {
    case .a(let ip), .aaaa(let ip): (record.name, ip, "")
    case .cname(let host), .ns(let host): (host, "", "")
    case .ptr(let host): (host, reversed ?? "", "")
    case .mx(let preference, let host): (host, "", "preference \(preference)")
    case .soa(let primary, let admin, let serial, let refresh, let retry, let expire, let minimum):
        (primary, "", "admin \(admin), serial \(serial), refresh \(refresh), retry \(retry), expire \(expire), minimum \(minimum)")
    case .srv(let priority, let weight, let port, let host): (host, "", "priority \(priority), weight \(weight), port \(port)")
    case .txt(let strings): (record.name, "", strings.joined())
    case .caa(let flags, let tag, let value): (record.name, "", "\(flags) \(tag) \"\(value)\"")
    case .svcb(let priority, let target, let params):
        (target == "." ? record.name : target, "", priority == 0 ? "alias" : (["priority \(priority)"] + (params.isEmpty ? [] : [params])).joined(separator: ", "))
    case .ds(let keyTag, let algorithm, let digestType, let digest):
        (record.name, "", "key tag \(keyTag), algorithm \(algorithm), digest type \(digestType), digest " + digest.map { String(format: "%02X", $0) }.joined())
    case .dnskey(let flags, let proto, let algorithm, let key):
        (record.name, "", "flags \(flags), protocol \(proto), algorithm \(algorithm), key tag \(keyTag(flags, proto, algorithm, key)), key \(Data(key).base64EncodedString())")
    case .unknown(let bytes): (record.name, "", "\\# \(bytes.count) " + bytes.map { String(format: "%02x", $0) }.joined())
    }
}

// RFC 4034 appendix B. Wrong for algorithm 1 (RSAMD5), which is retired.
func keyTag(_ flags: UInt16, _ proto: UInt8, _ algorithm: UInt8, _ key: [UInt8]) -> UInt16 {
    let rdata = [UInt8(flags >> 8), UInt8(flags & 0xFF), proto, algorithm] + key
    var sum: UInt32 = 0
    for (i, byte) in rdata.enumerated() { sum += i.isMultiple(of: 2) ? UInt32(byte) << 8 : UInt32(byte) }
    sum += sum >> 16 & 0xFFFF
    return UInt16(sum & 0xFFFF)
}
