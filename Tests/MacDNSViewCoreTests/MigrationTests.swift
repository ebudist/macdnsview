import Foundation
import Testing
@testable import MacDNSViewCore

private func a(_ target: String, _ address: String, server: String = "1.1.1.1", ttl: UInt32 = 300) -> Row {
    Row(index: 0, target: target, type: .a, name: target, address: address, data: "", section: .answer, ttl: ttl, server: server, error: nil, order: [])
}

private func failure(_ target: String, _ code: String, server: String = "1.1.1.1") -> Row {
    Row(index: 0, target: target, type: .a, name: target, address: "", data: code, section: nil, ttl: nil, server: server, error: code, order: [])
}

private let new: Set = ["203.0.113.10"]
private let old: Set = ["198.51.100.7"]

@Test func migrationLinesTakeAnOptionalOverride() {
    let entries = Migration.parse("""
    Example.com 203.0.113.20, 203.0.113.21
    # comment
    shop.example.com
    example.com 192.0.2.1
    203.0.113.5
    https://blog.example.com/path 203.0.113.30 not-an-ip
    """)
    #expect(entries.map(\.target.display) == ["example.com", "shop.example.com", "blog.example.com"])
    #expect(entries.map(\.expected) == [["203.0.113.20", "203.0.113.21"], [], ["203.0.113.30"]])
}

@Test func migrationStatusFollowsTheAnswers() {
    #expect(Migration.check("x.com", rows: [a("x.com", "203.0.113.10"), a("x.com", "203.0.113.10", server: "8.8.8.8")], new: new, old: old).status == .migrated)
    #expect(Migration.check("x.com", rows: [a("x.com", "198.51.100.7"), a("x.com", "198.51.100.7", server: "8.8.8.8")], new: new, old: old).status == .pending)
    #expect(Migration.check("x.com", rows: [a("x.com", "203.0.113.10"), a("x.com", "198.51.100.7", server: "8.8.8.8")], new: new, old: old).status == .propagating)
    #expect(Migration.check("x.com", rows: [a("x.com", "203.0.113.10"), a("x.com", "198.51.100.7")], new: new, old: old).status == .propagating)
    #expect(Migration.check("x.com", rows: [a("x.com", "192.0.2.99")], new: new, old: old).status == .unexpected)
    #expect(Migration.check("x.com", rows: [a("x.com", "104.16.132.229")], new: new, old: old).status == .proxied)
    #expect(Migration.check("x.com", rows: [a("x.com", "192.0.2.99")], new: new, old: []).status == .unexpected)
}

@Test func migrationFailsWithoutAnAnswer() {
    let check = Migration.check("x.com", rows: [failure("x.com", "NXDOMAIN"), a("y.com", "203.0.113.10")], new: new, old: old)
    #expect(check.status == .failed)
    #expect(check.error == "NXDOMAIN")
    #expect(check.answers.isEmpty)
}

@Test func migrationKeepsAnswersPerServerAndTheLowestTTL() {
    let check = Migration.check("x.com", rows: [a("x.com", "203.0.113.10", ttl: 300), a("x.com", "203.0.113.10", server: "8.8.8.8", ttl: 42),
                                                failure("x.com", "timeout", server: "9.9.9.9")], new: new, old: old)
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
