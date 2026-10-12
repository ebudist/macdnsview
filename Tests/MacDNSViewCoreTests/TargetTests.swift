import Testing
@testable import MacDNSViewCore

@Test func splitsOnEverySeparatorAndSkipsComments() {
    let text = """
    # hosts to check
    example.com, example.org;example.net\tgithub.com

      # indented comment
    gmail.com google.com
    """
    #expect(Target.parse(text).map(\.display) == ["example.com", "example.org", "example.net", "github.com", "gmail.com", "google.com"])
}

@Test func dropsDuplicatesKeepingFirstSeenOrder() {
    let text = "b.com a.com B.com. https://a.com/x bücher.de xn--bcher-kva.de"
    #expect(Target.parse(text).map(\.display) == ["b.com", "a.com", "bücher.de"])
}

@Test(arguments: [
    ("https://www.Example.com:8443/path?q=1", "www.example.com"),
    ("http://bücher.de/", "bücher.de"),
    ("www.example.com/path", "www.example.com"),
    ("ftp://files.example.com", "files.example.com"),
    ("Example.COM.", "example.com"),
])
func reducesToHost(_ input: String, _ expected: String) {
    #expect(Target.parse(input).map(\.display) == [expected])
}

@Test func urlExtractionOff() {
    #expect(Target.parse("example.com/path", extractHostFromURL: false).map(\.queryName) == ["example.com/path"])
}

@Test func idnQueriesPunycodeAndShowsUnicode() throws {
    let target = try #require(Target.parse("Bücher.de").first)
    #expect(target.display == "bücher.de")
    #expect(target.queryName == "xn--bcher-kva.de")
    #expect(target.kind == .name)
    #expect(Target.parse("例え.テスト").first?.queryName == "xn--r8jz45g.xn--zckzah")
}

@Test func serviceNamesPassThrough() {
    #expect(Target.parse("_imaps._tcp.gmail.com").first?.queryName == "_imaps._tcp.gmail.com")
}

@Test func addressesBecomeReverseNames() throws {
    let v4 = try #require(Target.parse("1.1.1.2").first)
    #expect(v4.kind == .ipv4)
    #expect(v4.queryName == "2.1.1.1.in-addr.arpa")
    #expect(v4.display == "1.1.1.2")

    let v6 = try #require(Target.parse("2001:DB8::1").first)
    #expect(v6.kind == .ipv6)
    #expect(v6.display == "2001:db8::1")
    #expect(v6.queryName == "1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.8.b.d.0.1.0.0.2.ip6.arpa")

    #expect(Target.parse("http://[2001:db8::1]:80/").first?.kind == .ipv6)
    #expect(Target.parse("1.2.3").first?.kind == .name)
}
