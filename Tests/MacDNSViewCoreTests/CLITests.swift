import Foundation
import Testing
@testable import MacDNSViewCore

@Test func parsesFlagsInBothForms() throws {
    let args = try CLI.parse(["example.com", "-t", "mx,txt,dmarc", "--server=9.9.9.9", "-F", "JSON", "-o", "out.json",
                              "--timeout", "1.5", "--no-errors", "--hide-additional", "1.1.1.1"])
    #expect(args.targets == ["example.com", "1.1.1.1"])
    #expect(args.options.types == [.mx, .txt])
    #expect(args.options.dmarc)
    #expect(!args.options.showErrors)
    #expect(args.options.hideAdditional)
    #expect(args.server == "9.9.9.9")
    #expect(args.format == .json)
    #expect(args.output == "out.json")
    #expect(args.timeout == 1.5)
}

@Test func defaultsMatchTheApp() throws {
    let args = try CLI.parse(["example.com"])
    #expect(args.options == LookupOptions())
    #expect(args.format == .table)
    #expect(args.timeout == 3)
}

@Test(arguments: [
    (["-t", "A,BOGUS"], "unknown record type BOGUS"),
    (["-F", "xml"], "unknown format xml"),
    (["--timeout", "0"], "--timeout needs a positive number"),
    (["--server"], "--server needs a value"),
    (["--frobnicate"], "unknown option --frobnicate"),
    (["-"], "unknown option -"),
])
func rejectsBadArguments(_ args: [String], _ message: String) {
    #expect {
        try CLI.parse(args)
    } throws: { ($0 as? CLI.UsageError)?.description.hasPrefix(message) == true }
}

private func fakeQuery(_ name: String, _ type: RecordType, _ server: Server) async throws -> Message {
    let records = name == "example.com" && type == .a
        ? [Record(name: name, type: .a, ttl: 60, section: .answer, data: .a("192.0.2.1"))] : []
    return Message(id: 1, isTruncated: false, responseCode: name.hasSuffix(".invalid") ? .nxDomain : .noError,
                   questionName: name, questionType: type, records: records)
}

private func run(_ args: [String], stdin: String? = nil) async -> CLI.Result {
    await CLI.run(args, stdin: { stdin }) { $0.query = fakeQuery }
}

@Test func exitStatusFollowsFailures() async {
    let ok = await run(["-t", "A,AAAA", "-s", "192.0.2.53", "example.com"])
    #expect(ok.status == 0) // AAAA comes back NODATA, which is an answer
    #expect(ok.stdout.hasPrefix("Index  Target"))
    #expect(ok.stdout.contains("192.0.2.1"))

    let failed = await run(["-t", "A", "-s", "192.0.2.53", "example.com", "nope.invalid"])
    #expect(failed.status == 1)
    #expect(failed.stdout.contains("NXDOMAIN"))
}

@Test func targetsFromStdinOnlyWithoutArguments() async {
    let piped = await run(["-t", "A", "-s", "192.0.2.53", "-F", "csv"], stdin: "example.com\n# comment\n")
    #expect(piped.stdout.split(separator: "\n").count == 2)

    let ignored = await run(["-t", "A", "-s", "192.0.2.53", "-F", "csv", "example.com"], stdin: "nope.invalid")
    #expect(ignored.status == 0)
}

@Test func usageProblemsExitTwo() async {
    #expect(await run([]).status == 2)
    #expect(await run(["--bogus"]).stderr.contains("unknown option --bogus"))
    #expect(await run(["-f", "/no/such/file"]).status == 2)
    #expect(await run(["-s", "1.1.1.1:0", "example.com"]).status == 2)
    #expect(await run(["--help"]).stdout.contains("Usage: macdnsview"))
    #expect(await run(["--version"]).stdout == "macdnsview \(version)\n")
}

@Test func writesOutputFile() async throws {
    let path = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let result = await run(["-t", "A", "-s", "192.0.2.53", "-F", "json", "-o", path, "example.com"])
    #expect(result.status == 0)
    #expect(result.stdout.isEmpty)
    #expect(try String(contentsOfFile: path, encoding: .utf8).contains("\"address\" : \"192.0.2.1\""))
}

@Test func failOnDiffExitsOneWhenServersDisagree() async {
    let query: QueryFunction = { name, type, server in
        let records = type == .a ? [Record(name: name, type: .a, ttl: 60, section: .answer, data: .a(server.host == "192.0.2.53" ? "192.0.2.1" : "192.0.2.2"))] : []
        return Message(id: 1, isTruncated: false, responseCode: .noError, questionName: name, questionType: type, records: records)
    }
    let args = ["-t", "A", "-s", "192.0.2.53,192.0.2.54", "-F", "csv", "example.com"]
    #expect(await CLI.run(args, stdin: { nil }) { $0.query = query }.status == 0)
    let strict = await CLI.run(args + ["--fail-on-diff"], stdin: { nil }) { $0.query = query }
    #expect(strict.status == 1)
    #expect(strict.stdout.components(separatedBy: ",no,yes\n").count == 3)
}

@Test func expectChecksEachDomain() async {
    let migrated = await run(["--expect", "192.0.2.1", "-s", "192.0.2.53", "example.com"])
    #expect(migrated.status == 0)
    #expect(migrated.stdout.hasPrefix("Domain       Status"))
    #expect(migrated.stdout.contains("Migrated"))

    let pending = await run(["--expect", "192.0.2.9", "--previous", "192.0.2.1", "-s", "192.0.2.53", "-F", "csv", "example.com", "nope.invalid"])
    #expect(pending.status == 1)
    #expect(pending.stdout.contains("example.com,Pending,192.0.2.9"))
    #expect(pending.stdout.contains("nope.invalid,Failed"))

    let override = await run(["--expect", "192.0.2.9", "-s", "192.0.2.53", "-F", "csv"], stdin: "example.com 192.0.2.1\n")
    #expect(override.status == 0)
}

@Test func expectNeedsOneTypeAndValidValues() async {
    #expect(await run(["--expect", "192.0.2.1", "-t", "A,MX", "example.com"]).stderr.contains("one record type"))
    #expect(await run(["--expect", "not-an-ip", "example.com"]).stderr.contains("not-an-ip is not a valid A value"))
    #expect(await run(["--expect", "mx.example.com", "-t", "MX", "-s", "192.0.2.53", "example.com"]).status == 1)
}
