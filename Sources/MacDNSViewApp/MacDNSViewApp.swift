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
