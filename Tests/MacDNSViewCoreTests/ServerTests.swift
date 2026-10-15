import Foundation
import Testing
@testable import MacDNSViewCore

@Test(arguments: [
    ("1.1.1.1", "1.1.1.1", UInt16(53)),
    (" 9.9.9.9 ", "9.9.9.9", 53),
    ("127.0.0.1:5353", "127.0.0.1", 5353),
    ("2606:4700::1111", "2606:4700::1111", 53),
    ("[2606:4700::1111]:853", "2606:4700::1111", 853),
    ("[::1]", "::1", 53),
    ("fe80::1%en0", "fe80::1%en0", 53),
])
func parsesServerInput(_ input: String, _ host: String, _ port: UInt16) throws {
    let server = try Server(parsing: input)
    #expect(server.host == host)
    #expect(server.port == port)
}

@Test func resolvesHostnameOnce() throws {
    let server = try Server(parsing: "localhost:5300")
    #expect(["127.0.0.1", "::1"].contains(server.host))
    #expect(server.port == 5300)
}

@Test func rejectsBadServerInput() {
    #expect(throws: ServerError.invalidPort("0")) { try Server(parsing: "1.1.1.1:0") }
    #expect(throws: ServerError.invalidPort("dns")) { try Server(parsing: "1.1.1.1:dns") }
    #expect(throws: ServerError.unresolvable("no-such-host.invalid")) { try Server(parsing: "no-such-host.invalid") }
}

@Test func serverDescriptionShowsPortOnlyWhenNotDefault() {
    #expect(Server(host: "1.1.1.1").description == "1.1.1.1")
    #expect(Server(host: "1.1.1.1", port: 5353).description == "1.1.1.1:5353")
    #expect(Server(host: "::1", port: 5353).description == "[::1]:5353")
}

@Test func picksLongestMatchingScopedServer() {
    let vpn = Server(host: "10.0.0.53"), lab = Server(host: "10.9.0.53"), reverse = Server(host: "10.0.0.54")
    let def = Server(host: "1.1.1.1")
    let config = ResolverConfiguration(defaultServers: [def], scopedServers: [
        "corp.internal": [vpn],
        "lab.corp.internal": [lab],
        "10.in-addr.arpa": [reverse],
    ])
    #expect(config.servers(for: "db.corp.internal") == [vpn])
    #expect(config.servers(for: "corp.internal") == [vpn])
    #expect(config.servers(for: "x.LAB.corp.internal") == [lab])
    #expect(config.servers(for: "notcorp.internal") == [def])
    #expect(config.servers(for: "example.com") == [def])
    #expect(config.servers(for: "4.3.2.10.in-addr.arpa") == [reverse])
}

@Test func parsesResolverFiles() {
    let text = """
    # VPN
    nameserver 10.0.0.53
    nameserver 10.0.0.54
    port 5353
    search_order 1
    """
    let (domain, servers) = parseResolverFile(name: "Corp.Internal.", contents: text)
    #expect(domain == "corp.internal")
    #expect(servers == [Server(host: "10.0.0.53", port: 5353), Server(host: "10.0.0.54", port: 5353)])
    #expect(parseResolverFile(name: "x", contents: "domain test.\nnameserver ::1").domain == "test")
}

@Test func readsResolverDirectory() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try "nameserver 10.1.2.3\n".write(to: dir.appending(path: "corp.internal"), atomically: true, encoding: .utf8)
    try "# mdns only\n".write(to: dir.appending(path: "local"), atomically: true, encoding: .utf8)

    let config = ResolverConfiguration.system(resolverDirectory: dir)
    #expect(config.scopedServers["corp.internal"] == [Server(host: "10.1.2.3")])
    #expect(config.scopedServers["local"] == nil)
    // Every Mac with a network has a default resolver, CI runners included.
    #expect(!config.defaultServers.isEmpty)
}

@Test func serverListsSplitOnCommasAndSpaces() throws {
    #expect(try Server.list(parsing: "1.1.1.1, 8.8.8.8 [2606:4700::1111]:5353") ==
        [Server(host: "1.1.1.1"), Server(host: "8.8.8.8"), Server(host: "2606:4700::1111", port: 5353)])
    #expect(try Server.list(parsing: " ") == [])
}
