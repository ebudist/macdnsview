import Testing
@testable import MacDNSViewCore

@Test func cloudflareRangesMatchAtTheirEdges() {
    #expect(Cloudflare.range(of: "104.16.0.0") == "104.16.0.0/13")
    #expect(Cloudflare.range(of: "104.23.255.255") == "104.16.0.0/13")
    #expect(Cloudflare.range(of: "104.24.0.1") == "104.24.0.0/14")
    #expect(Cloudflare.range(of: "104.15.255.255") == nil)
    #expect(Cloudflare.range(of: "2606:4700::6810:84e5") == "2606:4700::/32")
    #expect(Cloudflare.range(of: "2a06:98c7:ffff::1") == "2a06:98c0::/29")
    #expect(Cloudflare.range(of: "2a06:98c8::1") == nil)
    #expect(Cloudflare.range(of: "93.184.215.14") == nil)
    #expect(Cloudflare.range(of: "not an address") == nil)
}

@Test func cloudflareMatchesAnswerRowsOnly() {
    func row(_ type: RecordType, name: String = "example.com", address: String = "", section: Section? = .answer, error: String? = nil) -> Row {
        Row(index: 1, target: "example.com", type: type, name: name, address: address, data: "", section: section,
            ttl: 300, server: "1.1.1.1", error: error, order: [])
    }
    #expect(Cloudflare.match(row(.a, address: "172.64.1.1")) == .range("172.64.0.0/13"))
    #expect(Cloudflare.match(row(.a, address: "172.64.1.1", section: .additional)) == nil)
    #expect(Cloudflare.match(row(.ns, name: "gabe.ns.cloudflare.com.")) == .nameserver)
    #expect(Cloudflare.match(row(.ns, name: "a.iana-servers.net")) == nil)
    #expect(Cloudflare.match(row(.mx, name: "mx.cloudflare.com")) == nil)
    #expect(Cloudflare.match(row(.a, section: nil, error: "NXDOMAIN")) == nil)
}
