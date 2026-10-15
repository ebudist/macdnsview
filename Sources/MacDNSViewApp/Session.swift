import Foundation
import MacDNSViewCore
import Observation
import SwiftUI

/// Everything the window shows. Views hold no `@State`: in the macOS 27 SDK it is a macro whose plugin ships only with Xcode.
@MainActor @Observable
final class Session {
    var showingSheet = false
    var showingInspector = false
    var showingFilter = false
    var importing = false
    var problem: String?
    var selection = Set<Row.ID>()
    var sortOrder: [KeyPathComparator<Row>] = []
    var search = ""
    var outcomes = Set(Outcome.allCases)

    var targetsText: String { didSet { defaults.set(targetsText, forKey: "targets") } }
    var serverText: String { didSet { defaults.set(serverText, forKey: "server") } }
    var options: LookupOptions { didSet { defaults.set(try? JSONEncoder().encode(options), forKey: "options") } }
    var columns: TableColumnCustomization<Row> { didSet { defaults.set(try? JSONEncoder().encode(columns), forKey: "columns") } }

    private(set) var rows: [Row] = []
    private(set) var isRunning = false
    private(set) var targetCount = 0
    private(set) var wasStopped = false
    private var task: Task<Void, Never>?
    private let defaults = UserDefaults.standard

    init() {
        targetsText = defaults.string(forKey: "targets") ?? ""
        serverText = defaults.string(forKey: "server") ?? ""
        options = defaults.data(forKey: "options").flatMap { try? JSONDecoder().decode(LookupOptions.self, from: $0) } ?? LookupOptions()
        columns = defaults.data(forKey: "columns").flatMap { try? JSONDecoder().decode(TableColumnCustomization<Row>.self, from: $0) } ?? .init()
    }

    /// Checks the Server field; nil means it is usable (empty means the system configuration).
    func serverProblem() -> String? {
        let text = serverText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        do { _ = try Server.list(parsing: text); return nil } catch {
            let reason = switch error as? ServerError {
            case .invalidPort(let port): "\(port) is not a valid port"
            case .unresolvable(let host): "\(host) is not an IP address or a host name that resolves"
            case nil: "\(error)"
            }
            return reason + ". Separate servers by commas, such as 1.1.1.1, 8.8.8.8 or 9.9.9.9:53."
        }
    }

    func run() {
        task?.cancel()
        let targets = Target.parse(targetsText, extractHostFromURL: options.extractHostFromURL)
        let lookup = Lookup(options: options, servers: (try? Server.list(parsing: serverText)) ?? [])
        rows = []
        selection = []
        targetCount = targets.count
        wasStopped = false
        isRunning = !targets.isEmpty
        task = Task {
            for await row in lookup.stream(targets) {
                guard !Task.isCancelled else { return }
                rows.append(row)
            }
            guard !Task.isCancelled else { return }
            settle()
        }
    }

    func stop() {
        guard isRunning else { return }
        task?.cancel()
        wasStopped = true
        settle()
    }

    // Arrival order is a race between Servers; settle into the order the CLI prints.
    private func settle() {
        rows = Lookup.canonical(rows)
        selection = [] // indexes changed
        isRunning = false
    }

    func load(_ url: URL) throws {
        targetsText = try String(contentsOf: url, encoding: .utf8)
    }
}

extension Session {
    var visibleRows: [Row] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let filtered = rows.filter { row in
            outcomes.contains(row.outcome) && (query.isEmpty ||
                [row.target, row.typeName, row.name, row.address, row.data, row.server].contains { $0.localizedCaseInsensitiveContains(query) })
        }
        return sortOrder.isEmpty ? filtered : filtered.sorted(using: sortOrder)
    }

    var selectedRows: [Row] { visibleRows.filter { selection.contains($0.id) } }
    var isFiltered: Bool { !search.isEmpty || outcomes.count < Outcome.allCases.count }
}

enum Outcome: String, CaseIterable {
    case ok = "OK", noData = "NODATA", failed = "Failed"

    var color: Color { switch self { case .ok: .green; case .noData: .orange; case .failed: .red } }
}

extension Row {
    var outcome: Outcome { error == nil ? .ok : isFailure ? .failed : .noData }
}
