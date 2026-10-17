import Foundation
import MacDNSViewCore
import Observation
import SwiftUI

/// Everything the window shows. Views hold no `@State`: in the macOS 27 SDK it is a macro whose plugin ships only with Xcode.
@MainActor @Observable
final class Session {
    var showingSheet = false
    var showingInspector = true
    var showingExport = false
    var exportFormat = ExportFormat.csv
    var exportSelected = false
    var savingName: String?
    var copiedCommand = false
    var pane = Pane.results
    var onlyDiffers = false
    var cloudflareFilter = CloudflareFilter.any
    var importing = false
    var problem: String?
    var selection = Set<Row.ID>()
    var sort: SortKey?
    var popover: Popover?
    var showingSidebar = true
    private(set) var toast: String?
    private var toastTask: Task<Void, Never>?
    private var beforeNewList: (targets: String, list: String?)?
    var search = ""
    var outcomes = Set(Outcome.allCases)
    var autoRefresh = 0 { didSet { scheduleRefresh() } }
    private(set) var nextRefresh: Date?
    private(set) var events: [WatchEvent] = []
    private(set) var history: [HistoryEntry] { didSet { defaults.set(try? JSONEncoder().encode(history), forKey: "history") } }

    var targetsText: String { didSet { defaults.set(targetsText, forKey: "targets") } }
    var serverText: String { didSet { defaults.set(serverText, forKey: "server") } }
    var options: LookupOptions { didSet { defaults.set(try? JSONEncoder().encode(options), forKey: "options") } }
    var visibleColumns: Set<String> { didSet { defaults.set(Array(visibleColumns), forKey: "visibleColumns") } }
    var savedLists: [SavedList] { didSet { defaults.set(try? JSONEncoder().encode(savedLists), forKey: "savedLists") } }
    var currentList: String?

    private(set) var rows: [Row] = []
    private(set) var isRunning = false
    private(set) var targetCount = 0
    private(set) var wasStopped = false
    private(set) var changed = Set<Row.ID>()
    private(set) var removed: [Row] = []
    private(set) var finishedAt: Date?
    private var task: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var runKey = ""
    private var previous: (key: String, rows: [Row])?
    private let defaults = UserDefaults.standard

    init() {
        targetsText = defaults.string(forKey: "targets") ?? ""
        serverText = defaults.string(forKey: "server") ?? ""
        options = defaults.data(forKey: "options").flatMap { try? JSONDecoder().decode(LookupOptions.self, from: $0) } ?? LookupOptions()
        visibleColumns = defaults.stringArray(forKey: "visibleColumns").map(Set.init) ?? ["index", "target", "type", "data", "ttl", "server", "time", "validated", "differs"]
        savedLists = defaults.data(forKey: "savedLists").flatMap { try? JSONDecoder().decode([SavedList].self, from: $0) } ?? []
        history = defaults.data(forKey: "history").flatMap { try? JSONDecoder().decode([HistoryEntry].self, from: $0) } ?? []
    }

    func saveList(as name: String) {
        beforeNewList = nil
        savedLists.removeAll { $0.name == name }
        savedLists.append(SavedList(name: name, targets: targetsText, server: serverText, options: options))
        savedLists.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        currentList = name
    }

    func loadList(_ list: SavedList) {
        targetsText = list.targets
        serverText = list.server
        options = list.options
        currentList = list.name
    }

    static let intervals: [(seconds: Int, menu: String, short: String)] = [(0, "Off", "Off"), (30, "Every 30 seconds", "30 s"), (60, "Every minute", "1 min"),
                                                                                 (300, "Every 5 minutes", "5 min"), (900, "Every 15 minutes", "15 min")]

    func openLookup() {
        popover = nil
        problem = nil
        savingName = nil
        showingSheet = true
    }

    func openExport() {
        popover = nil
        showingSheet = false
        showingExport = true
    }

    @discardableResult func closeOverlays() -> Bool {
        if popover != nil {
            popover = nil
        } else if showingSheet || showingExport {
            if showingSheet, let before = beforeNewList {
                targetsText = before.targets
                currentList = before.list
            }
            beforeNewList = nil
            showingSheet = false
            showingExport = false
            savingName = nil
        } else {
            return false
        }
        return true
    }

    func flash(_ message: String) {
        toastTask?.cancel()
        toast = message
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.2))
            if !Task.isCancelled { toast = nil }
        }
    }

    func select(offset: Int) {
        let rows = visibleRows
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { selection.contains($0.id) } ?? (offset > 0 ? -1 : rows.count)
        selection = [rows[min(max(current + offset, 0), rows.count - 1)].id]
    }

    func newList() {
        beforeNewList = (targetsText, currentList)
        targetsText = ""
        currentList = nil
        popover = nil
        problem = nil
        savingName = ""
        showingSheet = true
    }

    func showAllResults() {
        outcomes = Set(Outcome.allCases)
        onlyDiffers = false
        cloudflareFilter = .any
    }

    func runList(_ name: String) {
        guard let list = savedLists.first(where: { $0.name == name }) else { return }
        loadList(list)
        run()
    }

    func rerun(_ entry: HistoryEntry) {
        targetsText = entry.targets
        serverText = entry.server
        options = entry.options
        currentList = entry.list
        run()
    }

    func renameList(_ name: String, to newName: String) {
        guard let list = savedLists.first(where: { $0.name == name }) else { return }
        savedLists.removeAll { $0.name == name || $0.name == newName }
        savedLists.append(SavedList(name: newName, targets: list.targets, server: list.server, options: list.options))
        savedLists.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if currentList == name { currentList = newName }
    }

    func deleteList(_ name: String) {
        savedLists.removeAll { $0.name == name }
        if currentList == name { currentList = nil }
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
        beforeNewList = nil
        task?.cancel()
        let targets = Target.parse(targetsText, extractHostFromURL: options.extractHostFromURL)
        let lookup = Lookup(options: options, servers: (try? Server.list(parsing: serverText)) ?? [])
        rows = []
        selection = []
        changed = []
        removed = []
        runKey = targetsText + "\n" + serverText
        targetCount = targets.count
        wasStopped = false
        isRunning = !targets.isEmpty
        pane = pane == .watch ? .watch : .results
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

    private func scheduleRefresh() {
        timer?.cancel()
        nextRefresh = nil
        guard autoRefresh > 0 else { return }
        timer = Task {
            while !Task.isCancelled {
                nextRefresh = Date() + Double(autoRefresh)
                try? await Task.sleep(for: .seconds(autoRefresh))
                if !Task.isCancelled, !isRunning { run() }
            }
        }
    }

    private func compareWithPrevious() {
        func key(_ row: Row) -> [String] { [row.target, row.typeName, row.server, row.name, row.address, row.data, row.error ?? ""] }
        if let previous, previous.key == runKey {
            let before = Set(previous.rows.map(key)), after = Set(rows.map(key))
            changed = Set(rows.filter { !before.contains(key($0)) }.map(\.id))
            removed = previous.rows.filter { !after.contains(key($0)) }.enumerated().map { i, row in
                var row = row
                row.index = rows.count + i + 1
                return row
            }
        }
        if autoRefresh > 0, previous?.key == runKey {
            func line(_ row: Row) -> String {
                [row.target, row.typeName, row.server, [row.address, row.data, row.error ?? ""].first { !$0.isEmpty } ?? row.name].joined(separator: "  ")
            }
            events.insert(WatchEvent(date: Date(), changed: rows.filter { changed.contains($0.id) }.map(line), removed: removed.map(line)), at: 0)
        }
        previous = (runKey, rows)
        finishedAt = Date()
    }

    // Arrival order is a race between Servers; settle into the order the CLI prints.
    private func settle() {
        rows = Lookup.canonical(rows)
        selection = [] // indexes changed
        isRunning = false
        if !wasStopped { compareWithPrevious() }
        let count = { (outcome: Outcome) in self.rows.filter { $0.outcome == outcome }.count }
        let entry = HistoryEntry(date: Date(), list: currentList, targets: targetsText, server: serverText, options: options,
                                 targetCount: targetCount, rows: rows.count, ok: count(.ok), noData: count(.noData), failed: count(.failed))
        history = Array(([entry] + history).prefix(50))
    }

    func load(_ url: URL) throws {
        targetsText = try String(contentsOf: url, encoding: .utf8)
    }
}

extension Session {
    var visibleRows: [Row] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let cloudflare = cloudflareFilter == .any ? [:] : cloudflareTargets
        let filtered = rows.filter { row in
            outcomes.contains(row.outcome) && (!onlyDiffers || row.differs == true) &&
                (cloudflareFilter == .any || (cloudflareFilter == .only) == (cloudflare[row.target] != nil)) && (query.isEmpty ||
                [row.target, row.typeName, row.name, row.address, row.data, row.server].contains { $0.localizedCaseInsensitiveContains(query) })
        }
        guard let sort else { return filtered }
        return filtered.sorted { a, b in
            let (x, y) = (a.sortValue(sort.column), b.sortValue(sort.column))
            let ascending = switch (x, y) {
            case (.number(let x), .number(let y)): x < y
            case (.text(let x), .text(let y)): x.localizedStandardCompare(y) == .orderedAscending
            default: false
            }
            return sort.ascending ? ascending : !ascending && x != y
        }
    }

    var selectedRows: [Row] { visibleRows.filter { selection.contains($0.id) } }
    var isFiltered: Bool { !search.isEmpty || outcomes.count < Outcome.allCases.count || onlyDiffers || cloudflareFilter != .any }

    var cloudflareTargets: [String: String] {
        var via: [String: Set<String>] = [:]
        for row in rows {
            switch Cloudflare.match(row) {
            case .range: via[row.target, default: []].insert("IP")
            case .nameserver: via[row.target, default: []].insert("NS")
            case nil: break
            }
        }
        return via.mapValues { $0.sorted().joined(separator: " + ") }
    }

    var progress: Double {
        targetCount == 0 ? 0 : Double(Set(rows.map(\.target)).count) / Double(targetCount)
    }
}

enum Pane: Hashable { case results, watch, history }

enum Popover { case autoRefresh, filter, lists, differsHint, cloudflareHint }

struct SortKey: Equatable {
    var column: String
    var ascending: Bool
}

enum SortValue: Equatable {
    case number(Int)
    case text(String)
}

extension Row {
    func sortValue(_ column: String) -> SortValue {
        switch column {
        case "index": .number(index)
        case "ttl": .number(ttl.map(Int.init) ?? -1)
        case "time": .number(time ?? -1)
        case "target": .text(target)
        case "type": .text(type.description)
        case "name": .text(name)
        case "address": .text(address)
        case "data": .text(data)
        case "section": .text(section?.rawValue ?? "")
        case "server": .text(server)
        case "validated": .text(validated.map { $0 ? "yes" : "no" } ?? "")
        default: .text(differs.map { $0 ? "yes" : "no" } ?? "")
        }
    }
}

enum CloudflareFilter: String, CaseIterable { case any = "Any", only = "On", exclude = "Off" }

struct WatchEvent: Identifiable {
    let id = UUID()
    let date: Date
    let changed: [String]
    let removed: [String]
}

struct HistoryEntry: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let list: String?
    let targets: String
    let server: String
    let options: LookupOptions
    let targetCount: Int
    let rows: Int
    let ok: Int
    let noData: Int
    let failed: Int
}

struct SavedList: Codable {
    let name: String
    let targets: String
    let server: String
    let options: LookupOptions
}

enum Outcome: String, CaseIterable {
    case ok = "OK", noData = "NODATA", failed = "Failed"

    var color: Color { switch self { case .ok: .green; case .noData: .orange; case .failed: .red } }
}

extension Row {
    var outcome: Outcome { error == nil ? .ok : isFailure ? .failed : .noData }
}
