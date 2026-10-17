import Foundation
import Testing
@testable import MacDNSViewCore

private func row(_ target: String, _ type: RecordType, name: String? = nil, address: String = "", data: String = "",
                 server: String = "1.1.1.1", ttl: UInt32 = 300) -> Row {
    Row(index: 0, target: target, type: type, name: name ?? target, address: address, data: data, section: .answer, ttl: ttl,
        server: server, error: nil, order: [])
}

private func a(_ target: String, _ address: String, server: String = "1.1.1.1", ttl: UInt32 = 300) -> Row {
    row(target, .a, address: address, server: server, ttl: ttl)
}

private func failure(_ target: String, _ code: String, server: String = "1.1.1.1") -> Row {
    Row(index: 0, target: target, type: .a, name: target, address: "", data: code, section: nil, ttl: nil, server: server, error: code, order: [])
}

private let new = ["203.0.113.10"]
private let old = ["198.51.100.7"]
private let kindA = Migration.Kind.record(.a)

@Test func migrationLinesTakeAnOptionalOverride() {
    let entries = Migration.parse("""
    Example.com 203.0.113.20, 203.0.113.21
    # comment
    shop.example.com
    example.com 192.0.2.1
    203.0.113.5
    https://blog.example.com/path 203.0.113.30
    """, kind: kindA)
    #expect(entries.map(\.target.display) == ["example.com", "shop.example.com", "blog.example.com"])
    #expect(entries.map(\.expected) == [["203.0.113.20", "203.0.113.21"], [], ["203.0.113.30"]])
}

@Test func migrationTextOverrideKeepsTheRestOfTheLine() {
    let entries = Migration.parse("example.com v=spf1 include:_spf.new.example ~all", kind: .record(.txt))
    #expect(entries.first?.expected == ["v=spf1 include:_spf.new.example ~all"])
    #expect(Migration.values("include:_spf.new.example, verify=abc 123", kind: .dmarc) == ["include:_spf.new.example", "verify=abc 123"])
    #expect(Migration.values("1.1.1.1, 2.2.2.2 3.3.3.3", kind: kindA) == ["1.1.1.1", "2.2.2.2", "3.3.3.3"])
}

@Test func migrationValuesAreCheckedPerType() {
    #expect(Migration.invalid(["203.0.113.10", "nope"], kind: kindA) == "nope")
    #expect(Migration.invalid(["2001:db8::1"], kind: kindA) == "2001:db8::1")
    #expect(Migration.invalid(["2001:db8::1"], kind: .record(.aaaa)) == nil)
    #expect(Migration.invalid(["mx.example.com"], kind: .record(.mx)) == nil)
    #expect(Migration.invalid(["https://mx.example.com"], kind: .record(.mx)) == "https://mx.example.com")
    #expect(Migration.invalid(["anything goes here"], kind: .record(.txt)) == nil)
}

@Test func migrationStatusFollowsTheAnswers() {
    func status(_ rows: [Row], old: [String] = old) -> MigrationStatus { Migration.check("x.com", rows: rows, kind: kindA, new: new, old: old).status }
    #expect(status([a("x.com", "203.0.113.10"), a("x.com", "203.0.113.10", server: "8.8.8.8")]) == .migrated)
    #expect(status([a("x.com", "198.51.100.7"), a("x.com", "198.51.100.7", server: "8.8.8.8")]) == .pending)
    #expect(status([a("x.com", "203.0.113.10"), a("x.com", "198.51.100.7", server: "8.8.8.8")]) == .propagating)
    #expect(status([a("x.com", "203.0.113.10"), a("x.com", "198.51.100.7")]) == .propagating)
    #expect(status([a("x.com", "192.0.2.99")]) == .unexpected)
    #expect(status([a("x.com", "104.16.132.229")]) == .proxied)
    #expect(status([a("x.com", "192.0.2.99")], old: []) == .unexpected)
}

@Test func migrationComparesHostsWithoutCaseOrTrailingDot() {
    let mx = [row("x.com", .mx, name: "MX1.NewHost.com.", data: "preference 10"), row("x.com", .mx, name: "mx2.newhost.com", data: "preference 20")]
    let check = Migration.check("x.com", rows: mx, kind: .record(.mx), new: ["mx1.newhost.com", "mx2.newhost.com."], old: [])
    #expect(check.status == .migrated)
    #expect(check.answers["1.1.1.1"] == ["mx1.newhost.com", "mx2.newhost.com"])
    let ns = [row("x.com", .ns, name: "ns1.oldhost.com")]
    #expect(Migration.check("x.com", rows: ns, kind: .record(.ns), new: ["ns1.newhost.com"], old: ["ns1.oldhost.com"]).status == .pending)
}

@Test func migrationMatchesTextByContaining() {
    let spf = row("x.com", .txt, data: "v=spf1 include:_spf.NewHost.com ~all")
    let verify = row("x.com", .txt, data: "google-site-verification=abc")
    let dmarc = row("x.com", .txt, name: "_dmarc.x.com", data: "v=DMARC1; p=reject")
    #expect(Migration.check("x.com", rows: [spf, verify, dmarc], kind: .record(.txt), new: ["include:_spf.newhost.com"], old: []).status == .migrated)
    #expect(Migration.check("x.com", rows: [verify, dmarc], kind: .record(.txt), new: ["include:_spf.newhost.com"], old: []).status == .pending)
    #expect(Migration.check("x.com", rows: [spf, row("x.com", .txt, data: "v=spf1 -all", server: "8.8.8.8")], kind: .record(.txt),
                            new: ["include:_spf.newhost.com"], old: []).status == .propagating)
    #expect(Migration.check("x.com", rows: [spf, dmarc], kind: .dmarc, new: ["p=reject"], old: []).status == .migrated)
    #expect(Migration.check("x.com", rows: [spf], kind: .dmarc, new: ["p=reject"], old: []).status == .failed)
}

@Test func migrationFailsWithoutAnAnswer() {
    let check = Migration.check("x.com", rows: [failure("x.com", "NXDOMAIN"), a("y.com", "203.0.113.10")], kind: kindA, new: new, old: old)
    #expect(check.status == .failed)
    #expect(check.error == "NXDOMAIN")
    #expect(check.answers.isEmpty)
}

@Test func migrationKeepsAnswersPerServerAndTheLowestTTL() {
    let check = Migration.check("x.com", rows: [a("x.com", "203.0.113.10", ttl: 300), a("x.com", "203.0.113.10", server: "8.8.8.8", ttl: 42),
                                                failure("x.com", "timeout", server: "9.9.9.9")], kind: kindA, new: new, old: old)
    #expect(check.status == .migrated)
    #expect(check.answers == ["1.1.1.1": ["203.0.113.10"], "8.8.8.8": ["203.0.113.10"]])
    #expect(check.ttl == 42)
    #expect(check.expected == ["203.0.113.10"])
}

@Test func tableExportWritesAnyHeaderAndLines() throws {
    #expect(export(header: ["Domain", "Status"], lines: [["x.com", "Migrated"], ["a,b", "Pending"]], as: .csv) == "Domain,Status\nx.com,Migrated\n\"a,b\",Pending\n")
    let json = try JSONSerialization.jsonObject(with: Data(export(header: ["Domain", "Status"], lines: [["x.com", "Migrated"]], as: .json).utf8)) as! [[String: String]]
    #expect(json == [["Domain": "x.com", "Status": "Migrated"]])
}
