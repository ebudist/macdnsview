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
            case "-t", "--type": try parseTypes(try value(), into: &parsed.options)
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
        let targets = Target.parse(text, extractHostFromURL: parsed.options.extractHostFromURL)
        guard !targets.isEmpty else { return Result(status: 2, stderr: "macdnsview: no targets\nTry 'macdnsview --help'.\n") }

        var server: Server?
        if let input = parsed.server {
            do { server = try Server(parsing: input) }
            catch { return Result(status: 2, stderr: "macdnsview: bad server \(input): \(error)\n") }
        }

        let transport = Transport(timeout: .milliseconds(Int(parsed.timeout * 1000)))
        var lookup = Lookup(options: parsed.options, server: server, transport: transport)
        configure(&lookup)
        let rows = await lookup.run(targets)
        let status: Int32 = rows.contains(where: \.isFailure) ? 1 : 0
        let rendered = export(rows, as: parsed.format)

        guard let output = parsed.output else { return Result(status: status, stdout: rendered) }
        do { try rendered.write(toFile: output, atomically: true, encoding: .utf8) }
        catch { return Result(status: 2, stderr: "macdnsview: cannot write \(output): \(error.localizedDescription)\n") }
        return Result(status: status)
    }

    public static let help = """
    Look up DNS records for many domains and IP addresses at once.

    Usage: macdnsview [options] [target ...]

    A target is a domain name, an IP address (looked up in reverse), or a URL.
    Targets also come from --file or, when none are given, from standard input.

    Options:
      -t, --type LIST        Record types, comma separated (default NS,MX,A,CNAME,SOA,TXT).
                             Available: NS, MX, A, AAAA, CNAME, SOA, SRV, TXT, CAA, DMARC
      -s, --server ADDR      DNS server: 1.1.1.1, 2606:4700::1111, host:port, [v6]:port, or a name.
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
      -h, --help             Show this help
          --version          Show the version

    Exit status: 0 when every lookup answered (an empty answer counts), 1 when any failed,
    2 for a usage or input problem.

    Examples:
      macdnsview example.com 1.1.1.1
      macdnsview -t MX,TXT,DMARC -F csv -o mail.csv gmail.com outlook.com
      pbpaste | macdnsview -s 9.9.9.9 -F json | jq '.[] | select(.error)'

    """
}
