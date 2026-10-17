import Foundation

/// The `macdnsview` command: argument parsing and one run, kept here so it is testable without a process.
public enum CLI {
    public struct Arguments: Equatable {
        public var targets: [String] = []
        public var file: String?
        public var options = LookupOptions()
        public var server: String?
        public var format = ExportFormat.table
        public var output: String?
        public var timeout: Double = 3
        public var failOnDiff = false
        public var expect: String?
        public var previous: String?
        public var typeGiven = false
        public var help = false
        public var version = false
    }

    public struct Result: Equatable {
        public var status: Int32
        public var stdout = ""
        public var stderr = ""
    }

    public struct UsageError: Error, Equatable, CustomStringConvertible {
        public let description: String
        init(_ description: String) { self.description = description }
    }

    static let typeNames: [String: RecordType] = Dictionary(uniqueKeysWithValues: RecordType.lookupOrder.map { ($0.description, $0) })

    public static func parse(_ args: [String]) throws -> Arguments {
        var parsed = Arguments()
        var queue = args[...]
        while let arg = queue.popFirst() {
            guard arg.hasPrefix("-") else {
                parsed.targets.append(arg)
                continue
            }
            // --flag=value is the same as --flag value
            var flag = arg, inline: String?
            if arg.hasPrefix("--"), let eq = arg.firstIndex(of: "=") {
                flag = String(arg[..<eq])
                inline = String(arg[arg.index(after: eq)...])
            }
            func value() throws -> String {
                if let inline { return inline }
                guard let next = queue.popFirst() else { throw UsageError("\(flag) needs a value") }
                return next
            }
            switch flag {
            case "-h", "--help": parsed.help = true
            case "--version": parsed.version = true
            case "-f", "--file": parsed.file = try value()
            case "-s", "--server": parsed.server = try value()
            case "-o", "--output": parsed.output = try value()
            case "-t", "--type":
                try parseTypes(try value(), into: &parsed.options)
                parsed.typeGiven = true
            case "--expect": parsed.expect = try value()
            case "--previous": parsed.previous = try value()
            case "-F", "--format":
                let name = try value()
                guard let format = ExportFormat(rawValue: name.lowercased()) else {
                    throw UsageError("unknown format \(name); use one of \(ExportFormat.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                parsed.format = format
            case "--timeout":
                let text = try value()
                guard let seconds = Double(text), seconds > 0 else { throw UsageError("--timeout needs a positive number of seconds, got \(text)") }
                parsed.timeout = seconds
            case "--ptr-for-addresses": parsed.options.ptrForEveryAddress = true
            case "--a-for-ptr-hosts": parsed.options.aForEveryPTRHost = true
            case "--no-reverse": parsed.options.reverseLookupAddresses = false
            case "--no-errors": parsed.options.showErrors = false
            case "--hide-additional": parsed.options.hideAdditional = true
            case "--no-url-extraction": parsed.options.extractHostFromURL = false
            case "--fail-on-diff": parsed.failOnDiff = true
            default: throw UsageError("unknown option \(arg)")
            }
        }
        return parsed
    }

    private static func parseTypes(_ list: String, into options: inout LookupOptions) throws {
        options.types = []
        options.dmarc = false
        for name in list.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces).uppercased() }) {
            if name == "DMARC" {
                options.dmarc = true
            } else if let type = typeNames[name] {
                options.types.insert(type)
            } else {
                throw UsageError("unknown record type \(name); use \((RecordType.lookupOrder.map(\.description) + ["DMARC"]).joined(separator: ", "))")
            }
        }
    }

    /// Runs one command. `stdin` is read only when no Target came from arguments or `--file`.
    public static func run(_ args: [String], stdin: () -> String?) async -> Result {
        await run(args, stdin: stdin) { _ in }
    }

    static func run(_ args: [String], stdin: () -> String?, configure: (inout Lookup) -> Void) async -> Result {
        let parsed: Arguments
        do { parsed = try parse(args) } catch { return Result(status: 2, stderr: "macdnsview: \(error)\nTry 'macdnsview --help'.\n") }
        if parsed.help { return Result(status: 0, stdout: help) }
        if parsed.version { return Result(status: 0, stdout: "macdnsview \(version)\n") }

        var text = parsed.targets.joined(separator: "\n")
        if let file = parsed.file {
            do { text += "\n" + (try String(contentsOfFile: file, encoding: .utf8)) }
            catch { return Result(status: 2, stderr: "macdnsview: cannot read \(file): \(error.localizedDescription)\n") }
        }
        if parsed.targets.isEmpty, parsed.file == nil, let input = stdin() { text = input }
        if let expect = parsed.expect { return await check(parsed, text: text, expect: expect, configure: configure) }
        let targets = Target.parse(text, extractHostFromURL: parsed.options.extractHostFromURL)
        guard !targets.isEmpty else { return Result(status: 2, stderr: "macdnsview: no targets\nTry 'macdnsview --help'.\n") }

        var servers: [Server] = []
        if let input = parsed.server {
            do { servers = try Server.list(parsing: input) }
            catch { return Result(status: 2, stderr: "macdnsview: bad server \(input): \(error)\n") }
        }

        let transport = Transport(timeout: .milliseconds(Int(parsed.timeout * 1000)))
        var lookup = Lookup(options: parsed.options, servers: servers, transport: transport)
        configure(&lookup)
        let rows = await lookup.run(targets)
        let disagree = parsed.failOnDiff && rows.contains { $0.differs == true }
        let status: Int32 = rows.contains(where: \.isFailure) || disagree ? 1 : 0
        return write(export(rows, as: parsed.format), status: status, to: parsed.output)
    }

    private static func write(_ rendered: String, status: Int32, to output: String?) -> Result {
        guard let output else { return Result(status: status, stdout: rendered) }
        do { try rendered.write(toFile: output, atomically: true, encoding: .utf8) }
        catch { return Result(status: 2, stderr: "macdnsview: cannot write \(output): \(error.localizedDescription)\n") }
        return Result(status: status)
    }

    private static func usage(_ message: String) -> Result {
        Result(status: 2, stderr: "macdnsview: \(message)\nTry 'macdnsview --help'.\n")
    }

    private static func check(_ parsed: Arguments, text: String, expect: String, configure: (inout Lookup) -> Void) async -> Result {
        let kind: Migration.Kind
        let types = parsed.options.types
        if !parsed.typeGiven {
            kind = .record(.a)
        } else if parsed.options.dmarc, types.isEmpty {
            kind = .dmarc
        } else if types.count == 1, !parsed.options.dmarc, let type = types.first {
            kind = .record(type)
        } else {
            return usage("--expect checks one record type; pick it with -t, such as -t A or -t MX")
        }
        let entries = Migration.parse(text, kind: kind)
        guard !entries.isEmpty else { return usage("no domains to check") }
        let new = Migration.values(expect, kind: kind), old = Migration.values(parsed.previous ?? "", kind: kind)
        if let bad = Migration.invalid(new + old + entries.flatMap { $0.expected + $0.previous }, kind: kind) {
            return usage("\(bad) is not a valid \(kind.name) value")
        }
        if new.isEmpty, let missing = entries.first(where: { $0.expected.isEmpty }) {
            return usage("no expected value for \(missing.target.display)")
        }

        var servers: [Server] = []
        if let input = parsed.server {
            do { servers = try Server.list(parsing: input) }
            catch { return Result(status: 2, stderr: "macdnsview: bad server \(input): \(error)\n") }
        }
        var options = LookupOptions()
        if case .record(let type) = kind { options.types = type == .a ? [.a, .aaaa] : [type] } else { options.types = []; options.dmarc = true }
        options.reverseLookupAddresses = false
        options.hideAdditional = true
        let transport = Transport(timeout: .milliseconds(Int(parsed.timeout * 1000)))
        var lookup = Lookup(options: options, servers: servers, transport: transport)
        configure(&lookup)
        let rows = await lookup.run(entries.map(\.target))
        let checks = entries.map {
            Migration.check($0.target.display, rows: rows, kind: kind, new: $0.expected.isEmpty ? new : $0.expected, old: $0.previous.isEmpty ? old : $0.previous)
        }
        let header = ["Domain", "Status", "Expected", "Answers", "Lowest TTL", "Leftover AAAA", "Error"]
        let lines = checks.map { check in
            [check.target, check.status.rawValue, check.expected.joined(separator: " | "),
             check.answers.keys.sorted().map { "\($0): \(check.answers[$0]!.joined(separator: " | "))" }.joined(separator: "; "),
             check.ttl.map(String.init) ?? "", (check.leftoverAAAA ?? []).joined(separator: " | "), check.error ?? ""]
        }
        let status: Int32 = checks.allSatisfy { $0.status == .migrated } ? 0 : 1
        return write(export(header: header, lines: lines, as: parsed.format), status: status, to: parsed.output)
    }

    public static let help = """
    Look up DNS records for many domains and IP addresses at once.

    Usage: macdnsview [options] [target ...]

    A target is a domain name, an IP address (looked up in reverse), or a URL.
    Targets also come from --file or, when none are given, from standard input.

    Options:
      -t, --type LIST        Record types, comma separated (default NS,MX,A,CNAME,SOA,TXT).
                             Available: NS, MX, A, AAAA, CNAME, SOA, SRV, TXT, CAA, HTTPS, SVCB, DS, DNSKEY, DMARC
      -s, --server LIST      DNS servers, comma separated: 1.1.1.1, 2606:4700::1111, host:port, [v6]:port, or a name.
                             DoH as https://host/path, DoT as tls://host or host:853.
                             With several, every query goes to each and the Differs column marks disagreements.
                             Without it, the system configuration picks one per target, VPN scopes included.
      -F, --format FORMAT    table (default), csv, tsv, json, or html
      -o, --output FILE      Write to FILE instead of standard output
      -f, --file FILE        Read targets from FILE, one or more per line, # starts a comment
          --timeout SECONDS  Per query, retried once over UDP (default 3)
          --ptr-for-addresses  Also look up PTR for every address in the answers
          --a-for-ptr-hosts    Also look up A for every host name in PTR answers
          --no-reverse         Query the selected types on IP addresses instead of PTR
          --no-errors          Leave out rows for failed lookups and empty answers
          --hide-additional    Leave out records from the Additional section
          --no-url-extraction  Treat input with a slash as a name, not a URL
          --fail-on-diff       Exit 1 when the servers given with --server disagree
          --expect VALUES      Check domains against the values they should have, one row per domain:
                               Migrated, Propagating, Pending, Unexpected, Proxied, or Failed.
                               One record type, A by default (-t to pick another). A line may give
                               its own values: example.com 203.0.113.10 | 198.51.100.7
          --previous VALUES    The old values, to tell answers not changed yet from unexpected ones
      -h, --help             Show this help
          --version          Show the version

    Exit status: 0 when every lookup answered (an empty answer counts), 1 when any failed
    or, with --fail-on-diff, when servers disagree, 2 for a usage or input problem.
    With --expect: 0 when every domain is Migrated, 1 otherwise.

    Examples:
      macdnsview example.com 1.1.1.1
      macdnsview -t MX,TXT,DMARC -F csv -o mail.csv gmail.com outlook.com
      pbpaste | macdnsview -s 9.9.9.9 -F json | jq '.[] | select(.error)'
      macdnsview -t A -s 1.1.1.1,8.8.8.8 --fail-on-diff www.example.com
      macdnsview -s https://cloudflare-dns.com/dns-query,tls://1.1.1.1 example.com
      macdnsview --expect 203.0.113.10 --previous 198.51.100.7 -s 1.1.1.1,8.8.8.8 -f migrated.txt

    """
}
