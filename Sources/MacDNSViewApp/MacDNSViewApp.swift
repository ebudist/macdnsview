import AppKit
import MacDNSViewCore
import SwiftUI

@main
struct MacDNSViewApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    // The App value lives for the whole process, so a plain `let` owns the Session.
    private let session = Session()

    var body: some Scene {
        Window("MacDNSView", id: "main") {
            ContentView(session: session)
                .frame(minWidth: 1000, minHeight: 560)
                .onAppear { if session.targetsText.isEmpty { session.showingSheet = true } }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About MacDNSView") { showAbout() }
            }
            CommandGroup(replacing: .newItem) {
                Button("Look Up…") { session.openLookup() }
                    .keyboardShortcut("k")
                Button("Refresh") { session.run() }
                    .keyboardShortcut("r")
                    .disabled(session.targetsText.isEmpty)
                Button("Stop") { session.stop() }
                    .keyboardShortcut(".")
                    .disabled(!session.isRunning)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Export…") { session.openExport() }
                    .keyboardShortcut("s")
                    .disabled(session.rows.isEmpty)
            }
            CommandGroup(after: .textEditing) {
                Button("Find") { focusSearch() }
                    .keyboardShortcut("f")
            }
            CommandGroup(after: .sidebar) {
                Button(session.showingInspector ? "Hide Inspector" : "Show Inspector") { session.showingInspector.toggle() }
                    .keyboardShortcut("i")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run from `swift run` without a bundle, the process starts as a background app with no Dock icon or menu bar.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@MainActor private var aboutWindow: NSWindow?

@MainActor private func showAbout() {
    if aboutWindow == nil {
        let window = NSWindow(contentViewController: NSHostingController(rootView: AboutView()))
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(srgbRed: 0x2A / 255, green: 0x2A / 255, blue: 0x2A / 255, alpha: 1)
        aboutWindow = window
    }
    aboutWindow?.center()
    aboutWindow?.makeKeyAndOrderFront(nil)
}

private struct AboutView: View {
    private static let repository = URL(string: "https://github.com/ebudist/macdnsview")!
    private static let githubMark: NSImage = {
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16"><path d="M6.766 11.328c-2.063-.25-3.516-1.734-3.516-3.656 0-.781.281-1.625.75-2.188-.203-.515-.172-1.609.063-2.062.625-.078 1.468.25 1.968.703.594-.187 1.219-.281 1.985-.281.765 0 1.39.094 1.953.265.484-.437 1.344-.765 1.969-.687.218.422.25 1.515.046 2.047.5.593.766 1.39.766 2.203 0 1.922-1.453 3.375-3.547 3.64.531.344.89 1.094.89 1.954v1.625c0 .468.391.734.86.547C13.781 14.359 16 11.53 16 8.03 16 3.61 12.406 0 7.984 0 3.563 0 0 3.61 0 8.031a7.88 7.88 0 0 0 5.172 7.422c.422.156.828-.125.828-.547v-1.25c-.219.094-.5.156-.75.156-1.031 0-1.64-.562-2.078-1.609-.172-.422-.36-.672-.719-.719-.187-.015-.25-.093-.25-.187 0-.188.313-.328.625-.328.453 0 .844.281 1.25.86.313.452.64.655 1.031.655s.641-.14 1-.5c.266-.265.47-.5.657-.656"/></svg>"#
        let image = NSImage(data: Data(svg.utf8)) ?? NSImage()
        image.isTemplate = true
        return image
    }()

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
            Text("MacDNSView").font(.ui(15, .bold)).foregroundStyle(Color.white(0.92)).padding(.top, 10)
            Text("Version \(MacDNSViewCore.version)").font(.ui(11.5)).foregroundStyle(Color.t2).padding(.top, 4)
            Text("MIT License").font(.ui(11.5)).foregroundStyle(Color.t2).padding(.top, 2)
            HoverButton(action: { NSWorkspace.shared.open(Self.repository) }, normal: .white(0.1), hover: .white(0.16), radius: 7) {
                HStack(spacing: 7) {
                    Image(nsImage: Self.githubMark).renderingMode(.template).resizable().frame(width: 14, height: 14)
                    Text("View on GitHub").font(.ui(12.5, .medium))
                }
                .foregroundStyle(Color.white(0.9))
                .padding(.horizontal, 12)
                .frame(height: 28)
            }
            .help(Self.repository.absoluteString)
            .padding(.top, 16)
        }
        .padding(.top, 36)
        .padding(.bottom, 24)
        .frame(width: 280)
        .background(Color.sheet)
        .preferredColorScheme(.dark)
    }
}
