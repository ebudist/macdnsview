import Testing
@testable import MacDNSViewCore

@Test func versionIsSemVer() {
    #expect(version.split(separator: ".").count == 3)
}

@Test(arguments: [("0.10.1", "0.9.0", true), ("v0.11.0", "0.10.1", true), ("0.10.1", "0.10.1", false), ("0.9.9", "0.10.0", false),
                  ("1.0", "0.99.99", true), ("0.10.1", "0.10", true)])
func comparesVersionsByNumber(_ candidate: String, _ current: String, _ newer: Bool) {
    #expect(Release.isNewer(candidate, than: current) == newer)
}
