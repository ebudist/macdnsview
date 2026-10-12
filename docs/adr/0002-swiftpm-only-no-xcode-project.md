# SwiftPM only, no Xcode project

The repo has a `Package.swift` and no `.xcodeproj`. `scripts/bundle.sh` assembles `MacDNSView.app` from the SwiftPM build output, an `Info.plist`, and an `.icns` made with `iconutil`. This keeps `project.pbxproj` merge conflicts out of the repo and lets contributors and CI build with Command Line Tools alone. The cost is no SwiftUI Previews and no asset catalogs; Xcode can still open `Package.swift` directly for anyone who wants them.
