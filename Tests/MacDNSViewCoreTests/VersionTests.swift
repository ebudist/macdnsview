import Testing
@testable import MacDNSViewCore

@Test func versionIsSemVer() {
    #expect(version.split(separator: ".").count == 3)
}
