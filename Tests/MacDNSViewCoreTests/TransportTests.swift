import Foundation
import Network
import Testing
@testable import MacDNSViewCore

/// A DNS server on 127.0.0.1 that answers UDP and TCP on one port with whatever `udp` and `tcp` return.
private final class FakeServer: @unchecked Sendable {
    private let lock = NSLock()
    private var _udpQueries = 0
    private var listeners: [NWListener] = []
    private let queue = DispatchQueue(label: "fake-dns")
    let udp: @Sendable (Data) -> [Data]
    let tcp: @Sendable (Data) -> Data?
    private(set) var port: UInt16 = 0

    var udpQueries: Int { lock.withLock { _udpQueries } }

    init(udp: @escaping @Sendable (Data) -> [Data], tcp: @escaping @Sendable (Data) -> Data? = { _ in nil }) async throws {
        self.udp = udp
        self.tcp = tcp
        let udpListener = try await listen(udp: true, port: .any)
        port = udpListener.port!.rawValue
        listeners = [udpListener, try await listen(udp: false, port: udpListener.port!)]
    }

    deinit { listeners.forEach { $0.cancel() } }

    var server: Server { Server(host: "127.0.0.1", port: port) }

    private func listen(udp isUDP: Bool, port: NWEndpoint.Port) async throws -> NWListener {
        let parameters: NWParameters = isUDP ? .udp : .tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: queue)
            isUDP ? serveUDP(connection) : serveTCP(connection)
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: continuation.resume(returning: listener)
                case .failed(let error): continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    private func serveUDP(_ connection: NWConnection) {
        connection.receiveMessage { [self] data, _, _, _ in
            guard let data else { return }
            lock.withLock { _udpQueries += 1 }
            for reply in udp(data) { connection.send(content: reply, completion: .idempotent) }
            serveUDP(connection)
        }
    }

    private func serveTCP(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 2, maximumLength: 2) { [self] prefix, _, _, _ in
            guard let prefix, prefix.count == 2 else { return }
            let length = Int(prefix[prefix.startIndex]) << 8 | Int(prefix[prefix.startIndex + 1])
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { [self] data, _, _, _ in
                guard let data, let reply = tcp(data) else { return }
                connection.send(content: Data([UInt8(reply.count >> 8), UInt8(reply.count & 0xFF)]) + reply,
                                completion: .idempotent)
            }
        }
    }
}

/// Turns a query into a response carrying one A record per address. `idDelta` makes a mismatched ID.
private func answer(_ query: Data, _ addresses: [[UInt8]], truncated: Bool = false, idDelta: UInt16 = 0) -> Data {
    var bytes = [UInt8](query)
    let id = (UInt16(bytes[0]) << 8 | UInt16(bytes[1])) &+ idDelta
    bytes[0] = UInt8(id >> 8)
    bytes[1] = UInt8(id & 0xFF)
    bytes[2] = truncated ? 0x83 : 0x81
    bytes[3] = 0x80
    bytes[7] = UInt8(addresses.count)
    for address in addresses {
        bytes += [0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0x0E, 0x10, 0, 4] + address
    }
    return Data(bytes)
}

@Test func answersOverUDP() async throws {
    let fake = try await FakeServer(udp: { [answer($0, [[192, 0, 2, 1]])] })
    let message = try await Transport().query("example.com", type: .a, server: fake.server)
    #expect(message.records.map(\.data) == [.a("192.0.2.1")])
}

@Test func skipsDatagramsThatDoNotMatchTheQuery() async throws {
    let fake = try await FakeServer(udp: { [answer($0, [[6, 6, 6, 6]], idDelta: 1), answer($0, [[192, 0, 2, 2]])] })
    let message = try await Transport().query("example.com.", type: .a, server: fake.server)
    #expect(message.records.map(\.data) == [.a("192.0.2.2")])
}

@Test func retriesTruncatedAnswersOverTCP() async throws {
    let fake = try await FakeServer(
        udp: { [answer($0, [], truncated: true)] },
        tcp: { answer($0, (1 ... 40).map { [192, 0, 2, UInt8($0)] }) }
    )
    let message = try await Transport().query("example.com", type: .a, server: fake.server)
    #expect(!message.isTruncated)
    #expect(message.records.count == 40)
}

@Test func timesOutAfterRetrying() async throws {
    let fake = try await FakeServer(udp: { _ in [] })
    let transport = Transport(timeout: .milliseconds(200), retries: 1)
    await #expect(throws: TransportError.timeout) {
        try await transport.query("example.com", type: .a, server: fake.server)
    }
    #expect(fake.udpQueries == 2)
}

@Test func cancellationStopsTheQuery() async throws {
    let fake = try await FakeServer(udp: { _ in [] })
    let task = Task { try await Transport(timeout: .seconds(30)).query("example.com", type: .a, server: fake.server) }
    try await Task.sleep(for: .milliseconds(100))
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MACDNSVIEW_NET_TESTS"] == "1"))
func realServer() async throws {
    let message = try await Transport().query("example.com", type: .a, server: Server(host: "1.1.1.1"))
    #expect(message.responseCode == .noError)
    #expect(!message.records.isEmpty)
}
