import Foundation
import Network

public enum TransportError: Error, Equatable, CustomStringConvertible {
    case timeout
    case networkUnreachable
    case refused
    case failed(String)

    /// The code shown in an Error row.
    public var description: String {
        switch self {
        case .timeout: "timeout"
        case .networkUnreachable: "network unreachable"
        case .refused: "refused"
        case .failed(let reason): reason
        }
    }
}

/// Sends one query to one Server: UDP first, the same query over TCP when the answer comes back truncated.
/// DoT and DoH Servers get the query over TLS or HTTPS instead.
public struct Transport: Sendable {
    public var timeout: Duration
    /// Extra UDP attempts after a timeout. A dead UDP server reads as a timeout: Network.framework drops ICMP port unreachable.
    public var retries: Int

    public init(timeout: Duration = .seconds(3), retries: Int = 1) {
        self.timeout = timeout
        self.retries = retries
    }

    public func query(_ name: String, type: RecordType, server: Server) async throws -> Message {
        let id = UInt16.random(in: 0 ... .max)
        let query = try Message.query(id: id, name: name, type: type)
        let expected = name.hasSuffix(".") ? String(name.dropLast()).lowercased() : name.lowercased()
        let matches: @Sendable (Message) -> Bool = {
            $0.id == id && $0.questionType == type && $0.questionName.lowercased() == expected
        }
        for attempt in 0 ... retries {
            do {
                switch server.encryption {
                case .https(let url):
                    return try await https(query, url: url, matches: matches)
                case .tls(let name):
                    return try await Exchange.run(query, server: server, tcp: true, tls: name, timeout: timeout, matches: matches)
                case .none:
                    let udp = try await Exchange.run(query, server: server, tcp: false, timeout: timeout, matches: matches)
                    guard udp.isTruncated else { return udp }
                    return try await Exchange.run(query, server: server, tcp: true, timeout: timeout, matches: matches)
                }
            } catch TransportError.timeout where attempt < retries {
                continue
            }
        }
        throw TransportError.timeout // unreachable: the last attempt rethrows
    }

    private func https(_ query: Data, url: URL, matches: (Message) -> Bool) async throws -> Message {
        let (seconds, attoseconds) = timeout.components
        var request = URLRequest(url: url, timeoutInterval: Double(seconds) + Double(attoseconds) / 1e18)
        request.httpMethod = "POST"
        request.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
        request.setValue("application/dns-message", forHTTPHeaderField: "Accept")
        request.httpBody = query
        let reply: (Data, URLResponse)
        do { reply = try await URLSession.shared.data(for: request) } catch let error as URLError { throw map(error) }
        let status = (reply.1 as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw TransportError.failed("HTTP \(status)") }
        let message = try Message(decoding: reply.0)
        guard matches(message) else { throw TransportError.failed("mismatched response") }
        return message
    }
}

/// One connection, one answer. Whatever finishes first (answer, error, timeout, cancellation) wins.
private final class Exchange: @unchecked Sendable {
    private let connection: NWConnection
    private let query: Data
    private let tcp: Bool
    private let matches: @Sendable (Message) -> Bool
    private let queue = DispatchQueue(label: "macdnsview.transport")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Message, Error>?
    private var finished = false

    private init(_ query: Data, server: Server, tcp: Bool, tls: String?, matches: @escaping @Sendable (Message) -> Bool) {
        let port = NWEndpoint.Port(rawValue: server.port) ?? 53
        var parameters: NWParameters = tcp ? .tcp : .udp
        if let tls {
            let options = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(options.securityProtocolOptions, tls)
            parameters = NWParameters(tls: options)
        }
        connection = NWConnection(host: NWEndpoint.Host(server.host), port: port, using: parameters)
        self.query = query
        self.tcp = tcp
        self.matches = matches
    }

    static func run(_ query: Data, server: Server, tcp: Bool, tls: String? = nil, timeout: Duration,
                    matches: @escaping @Sendable (Message) -> Bool) async throws -> Message {
        let exchange = Exchange(query, server: server, tcp: tcp, tls: tls, matches: matches)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { exchange.start($0, timeout: timeout) }
        } onCancel: {
            exchange.finish(.failure(CancellationError()))
        }
    }

    private func start(_ continuation: CheckedContinuation<Message, Error>, timeout: Duration) {
        lock.lock()
        if finished {
            lock.unlock()
            return continuation.resume(throwing: CancellationError())
        }
        self.continuation = continuation
        lock.unlock()

        let (seconds, attoseconds) = timeout.components
        queue.asyncAfter(deadline: .now() + Double(seconds) + Double(attoseconds) / 1e18) { [self] in
            finish(.failure(TransportError.timeout))
        }
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready: send()
            case .waiting(let error), .failed(let error): finish(.failure(map(error)))
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func finish(_ result: Result<Message, Error>) {
        lock.lock()
        let continuation = finished ? nil : self.continuation
        finished = true
        lock.unlock()
        connection.cancel()
        continuation?.resume(with: result)
    }

    private func send() {
        var payload = query
        if tcp { payload.insert(contentsOf: [UInt8(query.count >> 8), UInt8(query.count & 0xFF)], at: 0) }
        connection.send(content: payload, completion: .contentProcessed { [self] error in
            if let error { return finish(.failure(map(error))) }
            tcp ? receiveTCP() : receiveUDP()
        })
    }

    // Stray or spoofed datagrams that do not match the query are skipped, not treated as the answer.
    private func receiveUDP() {
        connection.receiveMessage { [self] data, _, _, error in
            if let error { return finish(.failure(map(error))) }
            if let data, let message = try? Message(decoding: data), matches(message) {
                return finish(.success(message))
            }
            receiveUDP()
        }
    }

    private func receiveTCP() {
        connection.receive(minimumIncompleteLength: 2, maximumLength: 2) { [self] prefix, _, _, error in
            if let error { return finish(.failure(map(error))) }
            guard let prefix, prefix.count == 2 else { return finish(.failure(TransportError.failed("connection closed"))) }
            let length = Int(prefix[prefix.startIndex]) << 8 | Int(prefix[prefix.startIndex + 1])
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { [self] data, _, _, error in
                if let error { return finish(.failure(map(error))) }
                guard let data, data.count == length else { return finish(.failure(TransportError.failed("connection closed"))) }
                do {
                    let message = try Message(decoding: data)
                    finish(matches(message) ? .success(message) : .failure(TransportError.failed("mismatched response")))
                } catch {
                    finish(.failure(error))
                }
            }
        }
    }
}

private func map(_ error: URLError) -> TransportError {
    switch error.code {
    case .timedOut: .timeout
    case .notConnectedToInternet, .networkConnectionLost: .networkUnreachable
    case .cannotConnectToHost: .refused
    default: .failed(error.localizedDescription)
    }
}

private func map(_ error: NWError) -> TransportError {
    guard case .posix(let code) = error else { return .failed(error.debugDescription) }
    switch code {
    case .ETIMEDOUT: return .timeout
    case .ENETUNREACH, .EHOSTUNREACH, .ENETDOWN, .EHOSTDOWN: return .networkUnreachable
    case .ECONNREFUSED: return .refused
    default: return .failed(error.debugDescription)
    }
}
