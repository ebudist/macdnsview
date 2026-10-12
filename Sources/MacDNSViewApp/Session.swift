import Foundation
import MacDNSViewCore
import Observation
import SwiftUI

/// Everything the window shows. Views hold no `@State`: in the macOS 27 SDK it is a macro whose plugin ships only with Xcode.
@MainActor @Observable
final class Session {
    var showingSheet = false
    var showingInspector = false
    var importing = false
    var problem: String?
    var selection = Set<Row.ID>()
    var sortOrder: [KeyPathComparator<Row>] = []
    var search = ""

    var targetsText: String { didSet { defaults.set(targetsText, forKey: "targets") } }
    var serverText: String { didSet { defaults.set(serverText, forKey: "server") } }
    var options: LookupOptions { didSet { defaults.set(try? JSONEncoder().encode(options), forKey: "options") } }

    private(set) var rows: [Row] = []
    private(set) var isRunning = false
    private(set) var targetCount = 0
    private var task: Task<Void, Never>?
    private let defaults = UserDefaults.standard

    init() {
        targetsText = defaults.string(forKey: "targets") ?? ""
        serverText = defaults.string(forKey: "server") ?? ""
        options = defaults.data(forKey: "options").flatMap { try? JSONDecoder().decode(LookupOptions.self, from: $0) } ?? LookupOptions()
    }

    /// Checks the Server field; nil means it is usable (empty means the system configuration).
    func serverProblem() -> String? {
        let text = serverText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        do { _ = try Server(parsing: text); return nil } catch { return "\(error)" }
    }

    func run() {
        task?.cancel()
        let targets = Target.parse(targetsText, extractHostFromURL: options.extractHostFromURL)
        let text = serverText.trimmingCharacters(in: .whitespaces)
        let server = text.isEmpty ? nil : try? Server(parsing: text)
        let lookup = Lookup(options: options, server: server)
        rows = []
        selection = []
        targetCount = targets.count
        isRunning = !targets.isEmpty
        task = Task {
            for await row in lookup.stream(targets) { rows.append(row) }
            guard !Task.isCancelled else { return }
            // Arrival order is a race between Servers; settle into the order the CLI prints.
            rows = Lookup.canonical(rows)
            selection = [] // indexes changed
            isRunning = false
        }
    }

    func stop() {
        task?.cancel()
        isRunning = false
    }

    func load(_ url: URL) throws {
        targetsText = try String(contentsOf: url, encoding: .utf8)
    }
}

extension Session {
    var visibleRows: [Row] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let filtered = query.isEmpty ? rows : rows.filter { row in
            [row.target, row.typeName, row.name, row.address, row.data, row.server].contains { $0.localizedCaseInsensitiveContains(query) }
        }
        return sortOrder.isEmpty ? filtered : filtered.sorted(using: sortOrder)
    }

    var selectedRows: [Row] { visibleRows.filter { selection.contains($0.id) } }
}
