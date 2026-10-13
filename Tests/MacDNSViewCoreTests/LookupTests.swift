import Foundation
import Testing
@testable import MacDNSViewCore

/// Answers from a table keyed by "name type"; anything missing is NODATA, names under `.invalid` are NXDOMAIN.
private struct FakeDNS: Sendable {
    var answers: [String: [RecordData]] = [:]
    var additional: [String: [Record]] = [:]
    var failures: [String: TransportError] = [:]

    func query(_ name: String, _ type: RecordType, _ server: Server) async throws -> Message {
        let key = "\(name) \(type)"
        if let failure = failures[key] { throw failure }
        let records = (answers[key] ?? []).map { Record(name: name, type: Self.type(of: $0), ttl: 300, section: .answer, data: $0) }
        return Message(id: 1, isTruncated: false, responseCode: name.hasSuffix(".invalid") ? .nxDomain : .noError,
                       questionName: name, questionType: type, records: records + (additional[key] ?? []))
    }

    static func type(of data: RecordData) -> RecordType {
        switch data {
        case .a: .a
        case .aaaa: .aaaa
        case .cname: .cname
        case .ns: .ns
        case .ptr: .ptr
        case .mx: .mx
        case .soa: .soa
        case .srv: .srv
        case .txt: .txt
        case .caa: .caa
        case .unknown: RecordType(99)
        }
    }
}

private func lookup(_ fake: FakeDNS, _ configure: (inout LookupOptions) -> Void = { _ in }) -> Lookup {
    var options = LookupOptions()
    configure(&options)
    var lookup = Lookup(options: options, server: Server(host: "192.0.2.53"))
    lookup.query = fake.query
    return lookup
}

private let exampleCom: FakeDNS = {
    var fake = FakeDNS()
    fake.answers = [
        "example.com NS": [.ns("a.iana-servers.net"), .ns("b.iana-servers.net")],
        "example.com MX": [.mx(preference: 0, exchange: ".")],
        "example.com A": [.a("192.0.2.10")],
        "example.com SOA": [.soa(primary: "ns.icann.org", admin: "noc.dns.icann.org", serial: 1, refresh: 2, retry: 3, expire: 4, minimum: 5)],
        "example.com TXT": [.txt(["v=spf1 ", "-all"])],
    ]
    return fake
}()

@Test func defaultOptionsQueryInDNSDataViewOrder() async {
    let rows = await lookup(exampleCom).run(Target.parse("example.com"))
    #expect(rows.map(\.type) == [.ns, .ns, .mx, .a, .cname, .soa, .txt])
    #expect(rows.map(\.index) == Array(1 ... 7))
    #expect(rows.allSatisfy { $0.target == "example.com" && $0.server == "192.0.2.53" })
    #expect(rows[4].error == "NODATA") // CNAME
    #expect(!rows[4].isFailure)
    #expect(rows[3].address == "192.0.2.10")
    #expect(rows[5].name == "ns.icann.org")
    #expect(rows[5].data == "admin noc.dns.icann.org, serial 1, refresh 2, retry 3, expire 4, minimum 5")
    #expect(rows[6].data == "v=spf1 -all")
}

@Test func errorRowsAndTheirSwitch() async {
    var fake = exampleCom
    fake.failures["example.com MX"] = .timeout
    let rows = await lookup(fake).run(Target.parse("example.com nope.invalid"))
    let errors = rows.filter { $0.error != nil }
    #expect(errors.map(\.data) == ["timeout", "NODATA", "NXDOMAIN", "NXDOMAIN", "NXDOMAIN", "NXDOMAIN", "NXDOMAIN", "NXDOMAIN"])
    #expect(errors.filter(\.isFailure).count == 7)

    let quiet = await lookup(fake) { $0.showErrors = false }.run(Target.parse("example.com nope.invalid"))
    #expect(quiet.allSatisfy { $0.error == nil })
    #expect(quiet.count == 5)
}

@Test func addressTargetsGetOnlyPTRAndOneHopOfFollowUps() async {
    var fake = FakeDNS()
    fake.answers = ["1.2.0.192.in-addr.arpa PTR": [.ptr("host.example.com")], "host.example.com A": [.a("192.0.2.1")]]
    let plain = await lookup(fake).run(Target.parse("192.0.2.1"))
    #expect(plain.map(\.type) == [.ptr])
    #expect(plain[0].name == "host.example.com")
    #expect(plain[0].address == "192.0.2.1")

    let followed = await lookup(fake) { $0.aForEveryPTRHost = true; $0.ptrForEveryAddress = true }.run(Target.parse("192.0.2.1"))
    #expect(followed.map(\.type) == [.ptr, .a]) // the A answer does not trigger another PTR
    #expect(followed.allSatisfy { $0.target == "192.0.2.1" })
}

@Test func ptrForEveryAddressKeepsTheTarget() async {
    var fake = FakeDNS()
    fake.answers = ["example.com A": [.a("192.0.2.10")], "10.2.0.192.in-addr.arpa PTR": [.ptr("web.example.com")]]
    let rows = await lookup(fake) { $0.types = [.a]; $0.ptrForEveryAddress = true }.run(Target.parse("example.com"))
    #expect(rows.map(\.type) == [.a, .ptr])
    #expect(rows[1].target == "example.com")
    #expect(rows[1].address == "192.0.2.10")
}

@Test func dmarcAndDuplicates() async {
    var fake = FakeDNS()
    fake.answers = [
        "www.example.com A": [.cname("example.net"), .a("192.0.2.20")],
        "www.example.com CNAME": [.cname("example.net")],
        "_dmarc.www.example.com TXT": [.txt(["v=DMARC1; p=none"])],
    ]
    let rows = await lookup(fake) { $0.types = [.a, .cname]; $0.dmarc = true }.run(Target.parse("www.example.com"))
    #expect(rows.map(\.type) == [.cname, .a, .txt]) // the CNAME from the CNAME query is the same Record
    #expect(rows[2].name == "_dmarc.www.example.com")
    #expect(rows[2].target == "www.example.com")
}

@Test func additionalSectionCanBeHidden() async {
    var fake = FakeDNS()
    fake.answers = ["example.com NS": [.ns("ns1.example.com")]]
    fake.additional = ["example.com NS": [Record(name: "ns1.example.com", type: .a, ttl: 60, section: .additional, data: .a("192.0.2.53"))]]
    let shown = await lookup(fake) { $0.types = [.ns] }.run(Target.parse("example.com"))
    #expect(shown.map(\.section) == [.answer, .additional])
    let hidden = await lookup(fake) { $0.types = [.ns]; $0.hideAdditional = true }.run(Target.parse("example.com"))
    #expect(hidden.map(\.section) == [.answer])
}

@Test func dataColumnFormats() async {
    var fake = FakeDNS()
    fake.answers = [
        "example.com MX": [.mx(preference: 10, exchange: "mail.example.com")],
        "example.com SRV": [.srv(priority: 5, weight: 0, port: 993, target: "imap.example.com")],
        "example.com CAA": [.caa(flags: 0, tag: "issue", value: "pki.goog")],
    ]
    let rows = await lookup(fake) { $0.types = [.mx, .srv, .caa] }.run(Target.parse("example.com"))
    #expect(rows.map(\.name) == ["mail.example.com", "imap.example.com", "example.com"])
    #expect(rows.map(\.data) == ["preference 10", "priority 5, weight 0, port 993", "0 issue \"pki.goog\""])
}

@Test func systemConfigurationPicksScopedServers() async {
    var lookup = Lookup(options: { var o = LookupOptions(); o.types = [.a]; return o }())
    lookup.resolvers = { ResolverConfiguration(defaultServers: [Server(host: "1.1.1.1")], scopedServers: ["corp.internal": [Server(host: "10.0.0.53")]]) }
    lookup.query = FakeDNS().query
    let rows = await lookup.run(Target.parse("db.corp.internal example.com"))
    #expect(rows.map(\.server) == ["10.0.0.53", "1.1.1.1"])

    lookup.resolvers = { ResolverConfiguration(defaultServers: []) }
    #expect(await lookup.run(Target.parse("example.com")).map(\.data) == ["no DNS server"])
}

private actor Gauge {
    var current = 0, peak = 0
    func enter() { current += 1; peak = max(peak, current) }
    func leave() { current -= 1 }
}

@Test func respectsTheConcurrencyLimit() async {
    let gauge = Gauge()
    var lookup = lookup(FakeDNS()) { $0.types = [.a] }
    lookup.maxConcurrent = 4
    lookup.query = { name, type, _ in
        await gauge.enter()
        try await Task.sleep(for: .milliseconds(20))
        await gauge.leave()
        return Message(id: 1, isTruncated: false, responseCode: .noError, questionName: name, questionType: type, records: [])
    }
    let targets = Target.parse((1 ... 20).map { "host\($0).example.com" }.joined(separator: " "))
    let rows = await lookup.run(targets)
    #expect(rows.count == 20)
    #expect(await gauge.peak == 4)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MACDNSVIEW_NET_TESTS"] == "1"))
func realLookupThroughSystemConfiguration() async {
    let rows = await Lookup().run(Target.parse("example.com 1.1.1.1 nxdomain.invalid"))
    for row in rows { print(row.index, row.target, row.type, row.name, row.address, row.data, row.section?.rawValue ?? "-", row.ttl ?? 0, row.server) }
    #expect(rows.contains { $0.target == "example.com" && $0.type == .ns && $0.error == nil })
    #expect(rows.contains { $0.target == "1.1.1.1" && $0.name == "one.one.one.one" })
    #expect(rows.contains { $0.target == "nxdomain.invalid" && $0.error == "NXDOMAIN" })
}

@Test func optionsSurviveARoundTrip() throws {
    var options = LookupOptions()
    options.types = [.aaaa, .caa]
    options.dmarc = true
    options.hideAdditional = true
    let decoded = try JSONDecoder().decode(LookupOptions.self, from: JSONEncoder().encode(options))
    #expect(decoded == options)
}

@Test func duplicatesKeepTheirCanonicalPlaceWhateverArrivesFirst() async {
    var fake = FakeDNS()
    fake.answers = ["www.example.com A": [.cname("example.net"), .a("192.0.2.20")], "www.example.com CNAME": [.cname("example.net")]]
    var lookup = lookup(fake) { $0.types = [.a, .cname] }
    let answers = fake
    // Make the A answer arrive last.
    lookup.query = { name, type, server in
        if type == .a { try await Task.sleep(for: .milliseconds(50)) }
        return try await answers.query(name, type, server)
    }
    #expect(await lookup.run(Target.parse("www.example.com")).map(\.type) == [.cname, .a])
}

@Test func everyAddressOfANameGetsItsOwnRow() async {
    var fake = FakeDNS()
    fake.answers = ["example.com A": [.a("192.0.2.1"), .a("192.0.2.2")], "example.com AAAA": [.aaaa("2001:db8::1"), .aaaa("2001:db8::2")]]
    let rows = await lookup(fake) { $0.types = [.a, .aaaa] }.run(Target.parse("example.com"))
    #expect(rows.map(\.address) == ["192.0.2.1", "192.0.2.2", "2001:db8::1", "2001:db8::2"])
}
