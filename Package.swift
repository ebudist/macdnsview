// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacDNSView",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "MacDNSViewCore"),
        .executableTarget(name: "macdnsview", dependencies: ["MacDNSViewCore"]),
        // Not "MacDNSView": would collide with "macdnsview" in .build on case-insensitive APFS.
        .executableTarget(name: "MacDNSViewApp", dependencies: ["MacDNSViewCore"]),
        .testTarget(name: "MacDNSViewCoreTests", dependencies: ["MacDNSViewCore"], resources: [.copy("Fixtures")]),
    ]
)
