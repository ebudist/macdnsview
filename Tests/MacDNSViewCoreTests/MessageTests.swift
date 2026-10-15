import Foundation
import Testing
@testable import MacDNSViewCore

// Fixtures are real responses from 1.1.1.1 over TCP (2026-10-12), stored without the length prefix.
private func fixture(_ name: String) throws -> Message {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "bin", subdirectory: "Fixtures"))
    return try Message(decoding: Data(contentsOf: url))
}

// Header with one question for example.com A, followed by the given counts and record bytes.
private func message(an: UInt8 = 0, ns: UInt8 = 0, ar: UInt8 = 0, flags: [UInt8] = [0x81, 0x80], _ records: [UInt8]) -> Data {
    let question: [UInt8] = [7] + Array("example".utf8) + [3] + Array("com".utf8) + [0, 0, 1, 0, 1]
    return Data([0x12, 0x34] + flags + [0, 1, 0, an, 0, ns, 0, ar] + question + records)
}

// Record owned by a pointer to the question name at offset 12.
private func rr(type: UInt16, ttl: UInt32 = 300, _ rdata: [UInt8]) -> [UInt8] {
    [0xC0, 0x0C, UInt8(type >> 8), UInt8(type & 0xFF), 0, 1]
        + withUnsafeBytes(of: ttl.bigEndian, Array.init)
        + [UInt8(rdata.count >> 8), UInt8(rdata.count & 0xFF)] + rdata
}

@Test func queryEncoding() throws {
    let bytes = try Message.query(id: 0x1234, name: "example.com.", type: .mx)
    #expect(Array(bytes) == [0x12, 0x34, 0x01, 0x20, 0, 1, 0, 0, 0, 0, 0, 0,
                             7] + Array("example".utf8) + [3] + Array("com".utf8) + [0, 0, 15, 0, 1])
    #expect(Array(try Message.query(id: 0, name: ".", type: .ns).suffix(5)) == [0, 0, 2, 0, 1])
}

@Test func decodesServiceAndDNSSECTypes() throws {
    let https = try fixture("https-cloudflare.com")
    #expect(https.isAuthenticated)
    #expect(https.records.first?.data == .svcb(priority: 1, target: ".", params: "alpn=h3,h2 ipv4hint=104.16.132.229,104.16.133.229 ipv6hint=2606:4700::6810:84e5,2606:4700::6810:85e5"))

    let svcb = try fixture("svcb-_dns.resolver.arpa")
    #expect(!svcb.isAuthenticated)
    #expect(svcb.records.first?.data == .svcb(priority: 1, target: "one.one.one.one", params: "alpn=h2,h3 port=443 ipv4hint=1.1.1.1,1.0.0.1 ipv6hint=2606:4700:4700::1111,2606:4700:4700::1001 dohpath=/dns-query{?dns}"))

    let ds = try fixture("ds-cloudflare.com")
    let dnskey = try fixture("dnskey-cloudflare.com")
    guard case .ds(let tag, 13, 2, let digest) = ds.records.first?.data else { Issue.record("\(ds.records)"); return }
    #expect(digest.count == 32)
    // The DS names the key-signing key by its tag.
    let ksk = dnskey.records.compactMap { record -> UInt16? in
        guard case .dnskey(257, let proto, let algorithm, let key) = record.data else { return nil }
        return keyTag(257, proto, algorithm, key)
    }
    #expect(ksk == [tag])
}

@Test(arguments: ["a..com", String(repeating: "a", count: 64) + ".com", "bücher.de",
                  Array(repeating: String(repeating: "a", count: 63), count: 4).joined(separator: ".")])
func queryRejectsInvalidNames(_ name: String) {
    #expect(throws: MessageError.self) { try Message.query(name: name, type: .a) }
}

@Test func decodesEveryV1Type() throws {
    let cases: [(String, RecordData)] = [
        ("a-example.com", .a("172.66.147.243")),
        ("aaaa-example.com", .aaaa("2606:4700:10::ac42:93f3")),
        ("ns-example.com", .ns("hera.ns.cloudflare.com")),
        ("cname-www.github.com", .cname("github.com")),
        ("mx-gmail.com", .mx(preference: 5, exchange: "gmail-smtp-in.l.google.com")),
        ("soa-example.com", .soa(primary: "elliott.ns.cloudflare.com", admin: "dns.cloudflare.com", serial: 2416374680,
                                 refresh: 10000, retry: 2400, expire: 604800, minimum: 1800)),
        ("srv-_imaps._tcp.gmail.com", .srv(priority: 5, weight: 0, port: 993, target: "imap.gmail.com")),
        ("txt-google.com", .txt(["v=spf1 include:_spf.google.com ~all"])),
        ("caa-google.com", .caa(flags: 0, tag: "issue", value: "pki.goog")),
        ("ptr-1.1.1.1.in-addr.arpa", .ptr("one.one.one.one")),
    ]
    for (file, first) in cases {
        let m = try fixture(file)
        #expect(m.responseCode == .noError, "\(file)")
        #expect(m.records.first?.data == first, "\(file)")
        #expect(m.records.allSatisfy { $0.section == .answer }, "\(file)")
    }
    #expect(try fixture("mx-gmail.com").records.count == 5)
    #expect(try fixture("txt-google.com").records.count == 17)
}

@Test func followsCnameChain() throws {
    let m = try fixture("a-www.github.com")
    #expect(m.questionName == "www.github.com")
    #expect(m.questionType == .a)
    #expect(m.records.map(\.name) == ["www.github.com", "github.com"])
    #expect(m.records.map(\.type) == [.cname, .a])
    #expect(m.records[0].ttl == 3433)
}

@Test func nxdomainCarriesSoaInAuthority() throws {
    let m = try fixture("a-nxdomain.invalid")
    #expect(m.responseCode == .nxDomain)
    #expect(m.responseCode.description == "NXDOMAIN")
    #expect(m.records.count == 1)
    #expect(m.records[0].section == .authority)
    #expect(m.records[0].name == ".")
    #expect(m.records[0].type == .soa)
}

@Test func sectionsMultiStringTxtAndUnknownTypes() throws {
    let txt = rr(type: 16, [3] + Array("abc".utf8) + [2] + Array("de".utf8))
    let unknown = rr(type: 99, [1, 2, 3])
    let glue = rr(type: 1, [192, 0, 2, 1])
    let m = try Message(decoding: message(an: 2, ar: 1, txt + unknown + glue))
    #expect(m.records.map(\.section) == [.answer, .answer, .additional])
    #expect(m.records[0].data == .txt(["abc", "de"]))
    #expect(m.records[1].data == .unknown([1, 2, 3]))
    #expect(m.records[1].type.description == "TYPE99")
    #expect(m.records[2].data == .a("192.0.2.1"))
    #expect(m.records.allSatisfy { $0.name == "example.com" })
}

@Test(arguments: [
    ("00000000000000000000000000000001", "::1"),
    ("20010db8000000000000000000000001", "2001:db8::1"),
    ("20010db8000000010001000100010001", "2001:db8:0:1:1:1:1:1"),
    ("20010000000000010000000000000001", "2001:0:0:1::1"),
])
func ipv6TextForm(_ hex: String, _ expected: String) throws {
    let address = stride(from: 0, to: hex.count, by: 2).map { i -> UInt8 in
        let start = hex.index(hex.startIndex, offsetBy: i)
        return UInt8(hex[start ..< hex.index(start, offsetBy: 2)], radix: 16)!
    }
    let m = try Message(decoding: message(an: 1, rr(type: 28, address)))
    #expect(m.records[0].data == .aaaa(expected))
}

@Test func headerFlags() throws {
    let m = try Message(decoding: message(flags: [0x83, 0x82], []))
    #expect(m.id == 0x1234)
    #expect(m.isTruncated)
    #expect(m.responseCode == .servFail)
}

@Test func everyTruncationThrows() throws {
    let url = try #require(Bundle.module.url(forResource: "mx-gmail.com", withExtension: "bin", subdirectory: "Fixtures"))
    let full = try Data(contentsOf: url)
    for length in 0 ..< full.count {
        #expect(throws: MessageError.self) { try Message(decoding: full.prefix(length)) }
    }
}

@Test func rejectsPointersThatDoNotPointBackwards() {
    // Answer owner name is a pointer to itself, which would loop forever if followed.
    let selfPointer = message(an: 1, [0xC0, 29, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0])
    #expect(throws: MessageError.badCompressionPointer(offset: 29)) { try Message(decoding: selfPointer) }
}

@Test func rejectsRecordDataLongerThanItsType() {
    let m = message(an: 1, rr(type: 1, [1, 2, 3, 4, 5]))
    #expect(throws: MessageError.badRecordData(.a)) { try Message(decoding: m) }
}
