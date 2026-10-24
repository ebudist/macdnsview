import AppKit
import Charts
import MacDNSViewCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable
final class Monitor {
    static let defaultServers = "1.1.1.1, 8.8.8.8, 9.9.9.9"

    var targetsText: String { didSet { defaults.set(targetsText, forKey: "monitor.targets") } }
    var newText: String { didSet { defaults.set(newText, forKey: "monitor.new") } }
    var oldText: String { didSet { defaults.set(oldText, forKey: "monitor.old") } }
    var serverText: String { didSet { defaults.set(serverText, forKey: "monitor.server") } }
    var typeName: String {
        didSet {
            defaults.set(typeName, forKey: "monitor.type")
            if typeName != oldValue { reset() }
        }
    }
    var name: String? { didSet { defaults.set(name, forKey: "monitor.name") } }
    var includeWWW: Bool { didSet { defaults.set(includeWWW, forKey: "monitor.www") } }
    var saved: [SavedMonitor] { didSet { defaults.set(try? JSONEncoder().encode(saved), forKey: "monitor.saved") } }
    private(set) var events: [MonitorEvent] { didSet { defaults.set(try? JSONEncoder().encode(events), forKey: "monitor.events") } }
    private(set) var migratedAt: [String: Date] { didSet { defaults.set(try? JSONEncoder().encode(migratedAt), forKey: "monitor.migratedAt") } }
    private(set) var checks: [Migration.Check] { didSet { defaults.set(try? JSONEncoder().encode(checks), forKey: "monitor.checks") } }
    private(set) var runs: [MonitorRun] { didSet { defaults.set(try? JSONEncoder().encode(runs), forKey: "monitor.runs") } }
    private(set) var lastRun: Date? { didSet { defaults.set(lastRun, forKey: "monitor.lastRun") } }
    private var states: [String: MonitorState] { didSet { defaults.set(try? JSONEncoder().encode(states), forKey: "monitor.states") } }
    var interval = 0 { didSet { schedule() } }
    private(set) var nextRun: Date?
    var flash: (String) -> Void = { _ in }
    private var timer: Task<Void, Never>?

    var showingSetup = false
    var showingSavedMenu = false
    var importing = false
    var savingName: String?
    var problem: String?
    var filter: MigrationStatus?
    var search = ""
    var onlyDisagree = false
    var onlyLeftover = false
    var hiddenColumns: Set<String> { didSet { defaults.set(Array(hiddenColumns), forKey: "monitor.hiddenColumns") } }
    var selection = Set<String>()
    var selectionAnchor: String?

    private(set) var rows: [Row] = []
    private(set) var isRunning = false
    private(set) var isPaused = false
    private var finished = Set<String>()
    private var runConfig: SavedMonitor?
    private(set) var background: [String: (interval: Int, next: Date)] = [:]
    private(set) var backgroundRunning: String?
    private var backgroundTask: Task<Void, Never>?
    private(set) var domainCount = 0
    private var task: Task<Void, Never>?
    private let defaults = UserDefaults.standard

    init() {
        targetsText = defaults.string(forKey: "monitor.targets") ?? ""
        newText = defaults.string(forKey: "monitor.new") ?? ""
        oldText = defaults.string(forKey: "monitor.old") ?? ""
        serverText = defaults.string(forKey: "monitor.server") ?? Self.defaultServers
        typeName = defaults.string(forKey: "monitor.type") ?? "A"
        name = defaults.string(forKey: "monitor.name")
        includeWWW = defaults.bool(forKey: "monitor.www")
        hiddenColumns = Set(defaults.stringArray(forKey: "monitor.hiddenColumns") ?? [])
        saved = defaults.data(forKey: "monitor.saved").flatMap { try? JSONDecoder().decode([SavedMonitor].self, from: $0) } ?? []
        events = defaults.data(forKey: "monitor.events").flatMap { try? JSONDecoder().decode([MonitorEvent].self, from: $0) } ?? []
        migratedAt = defaults.data(forKey: "monitor.migratedAt").flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) } ?? [:]
        checks = defaults.data(forKey: "monitor.checks").flatMap { try? JSONDecoder().decode([Migration.Check].self, from: $0) } ?? []
        runs = defaults.data(forKey: "monitor.runs").flatMap { try? JSONDecoder().decode([MonitorRun].self, from: $0) } ?? []
        lastRun = defaults.object(forKey: "monitor.lastRun") as? Date
        states = defaults.data(forKey: "monitor.states").flatMap { try? JSONDecoder().decode([String: MonitorState].self, from: $0) } ?? [:]
        domainCount = checks.count
    }

    static let typeNames = ["A", "AAAA", "CNAME", "MX", "NS", "SOA", "SRV", "TXT", "CAA", "HTTPS", "SVCB", "DS", "DNSKEY", "DMARC"]

    func ordered(_ answers: some Sequence<String>, expected: [String]) -> [String] {
        answers.sorted { a, b in
            let (x, y) = (Migration.classify(a, kind: kind, new: expected, old: []) == .new, Migration.classify(b, kind: kind, new: expected, old: []) == .new)
            return x != y ? x : a < b
        }
    }

    var config: SavedMonitor { SavedMonitor(name: name ?? "", targets: targetsText, new: newText, old: oldText, server: serverText, type: typeName, www: includeWWW) }
    var kind: Migration.Kind { config.kind }
    var entries: [Migration.Entry] { config.entries }
    var leftoverCount: Int { checks.filter { $0.leftoverAAAA != nil }.count }
    var newValues: [String] { config.newValues }
    var oldValues: [String] { config.oldValues }
    var title: String { name ?? "Propagation Checker" }
    var isFiltered: Bool { onlyDisagree || onlyLeftover }
    var visibleChecks: [Migration.Check] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return checks.filter { check in
            (filter == nil || check.status == filter)
                && (!onlyDisagree || Set(check.answers.values.map(Set.init)).count > 1)
                && (!onlyLeftover || check.leftoverAAAA != nil)
                && (query.isEmpty || ([check.target] + check.expected + check.answers.values.joined()).contains { $0.localizedCaseInsensitiveContains(query) })
        }
    }
    var selectedCheck: Migration.Check? { selection.count == 1 ? visibleChecks.first { selection.contains($0.target) } : nil }
    var progress: Double { domainCount == 0 ? 0 : Double(finished.count) / Double(domainCount) }

    func count(_ status: MigrationStatus) -> Int { checks.filter { $0.status == status }.count }

    func problemText() -> String? {
        let entries = self.entries
        if entries.isEmpty { return "Add at least one domain, one per line." }
        if let bad = Migration.invalid(newValues + oldValues + entries.flatMap { $0.expected + $0.previous }, kind: kind) {
            return switch kind {
            case .record(.a): "\(bad) is not an IPv4 address."
            case .record(.aaaa): "\(bad) is not an IPv6 address."
            default: "\(bad) is not a host name."
            }
        }
        if newValues.isEmpty, let missing = entries.first(where: { $0.expected.isEmpty }) {
            return "Add the expected value, or put one after \(missing.target.display)."
        }
        let servers = serverText.trimmingCharacters(in: .whitespaces)
        if !servers.isEmpty, (try? Server.list(parsing: servers)) == nil {
            return "\(servers) has a server that is not an IP address or a host name that resolves."
        }
        return nil
    }

    func run() {
        task?.cancel()
        let config = self.config
        guard !config.entries.isEmpty else { return }
        rows = []
        finished = []
        runConfig = config
        domainCount = config.entries.count
        isPaused = false
        isRunning = true
        start(skipping: [])
    }

    private func start(skipping: Set<Int>) {
        guard let config = runConfig else { return }
        let targets = config.entries.map(\.target)
        task = Task {
            for await event in config.lookup.events(targets, skipping: skipping) {
                guard !Task.isCancelled else { return }
                switch event {
                case .row(let row): rows.append(row)
                case .done(let i): finished.insert(targets[i].display)
                }
            }
            guard !Task.isCancelled else { return }
            rows = Lookup.canonical(rows)
            isRunning = false
            record(config.checks(rows))
        }
    }

    func resume() {
        guard isPaused, let config = runConfig else { return run() }
        let targets = config.entries.map(\.target)
        isPaused = false
        isRunning = true
        start(skipping: Set(targets.indices.filter { finished.contains(targets[$0].display) }))
    }

    private func record(_ new: [Migration.Check]) {
        var state = MonitorState(checks: checks, events: events, migratedAt: migratedAt, lastRun: lastRun, runs: runs)
        let migrated = state.record(new, at: Date())
        (checks, events, migratedAt, lastRun, runs) = (state.checks, state.events, state.migratedAt, state.lastRun, state.runs ?? [])
        stash()
        state.notify(migrated, kind: kind, title: title)
        if interval > 0, state.isDone {
            interval = 0
            state.notifyDone(title: title)
            flash("Watch stopped: every domain is done")
        }
    }

    private func watchInBackground() {
        guard backgroundTask == nil else { return }
        backgroundTask = Task {
            while !background.isEmpty {
                if !isRunning, let due = background.filter({ $0.value.next <= Date() }).min(by: { $0.value.next < $1.value.next })?.key {
                    await runInBackground(due)
                } else {
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            backgroundTask = nil
        }
    }

    private func runInBackground(_ name: String) async {
        guard let config = saved.first(where: { $0.name == name }), let interval = background[name]?.interval else {
            background[name] = nil
            return
        }
        backgroundRunning = name
        var rows: [Row] = []
        for await row in config.lookup.stream(config.entries.map(\.target)) { rows.append(row) }
        backgroundRunning = nil
        // Dropped when the check was opened or stopped while this run was in flight.
        guard background[name] != nil else { return }
        background[name]?.next = Date() + Double(interval)
        var state = states[name] ?? MonitorState(checks: [], events: [], migratedAt: [:], lastRun: nil, runs: [])
        let migrated = state.record(config.checks(Lookup.canonical(rows)), at: Date())
        states[name] = state
        state.notify(migrated, kind: config.kind, title: name)
        if state.isDone {
            background[name] = nil
            state.notifyDone(title: name)
        }
    }

    private func detach() {
        stash()
        if let name, interval > 0, saved.contains(where: { $0.name == name }) {
            background[name] = (interval, nextRun ?? Date())
            watchInBackground()
        }
        stop()
        isPaused = false
        finished = []
        interval = 0
    }

    func progress(_ name: String) -> String? {
        let checks = name == self.name ? checks : states[name]?.checks ?? []
        return checks.isEmpty ? nil : "\(checks.filter { $0.status == .migrated }.count)/\(checks.count)"
    }

    func isWatched(_ name: String) -> Bool { name == self.name ? interval > 0 : background[name] != nil }

    func stopWatching(_ name: String) {
        if name == self.name { interval = 0 } else { background[name] = nil }
    }

    private func schedule() {
        timer?.cancel()
        nextRun = nil
        guard interval > 0 else { return }
        Notifier.requestAuthorization()
        if !isRunning { run() }
        timer = Task {
            while !Task.isCancelled {
                nextRun = Date() + Double(interval)
                try? await Task.sleep(for: .seconds(interval))
                while backgroundRunning != nil, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(500)) }
                if !Task.isCancelled, !isRunning { run() }
            }
        }
    }

    func clearEvents() {
        events = []
        stash()
    }

    func clearRuns() {
        runs = []
        stash()
    }

    private func stash() {
        guard let name, saved.contains(where: { $0.name == name }) else { return }
        states[name] = MonitorState(checks: checks, events: events, migratedAt: migratedAt, lastRun: lastRun, runs: runs)
    }

    func stop() {
        task?.cancel()
        if isRunning {
            rows = rows.filter { finished.contains($0.target) }
            isPaused = true
        }
        isRunning = false
    }

    func save(as name: String) {
        saved.removeAll { $0.name == name }
        saved.append(SavedMonitor(name: name, targets: targetsText, new: newText, old: oldText, server: serverText, type: typeName, www: includeWWW))
        saved.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        self.name = name
        stash()
    }

    func load(_ monitor: SavedMonitor) {
        detach()
        targetsText = monitor.targets
        newText = monitor.new
        oldText = monitor.old
        serverText = monitor.server
        typeName = monitor.type ?? "A"
        includeWWW = monitor.www ?? false
        name = monitor.name
        let state = states[monitor.name]
        checks = state?.checks ?? []
        events = state?.events ?? []
        runs = state?.runs ?? []
        migratedAt = state?.migratedAt ?? [:]
        lastRun = state?.lastRun
        domainCount = checks.count
        rows = []
        selection = []
        filter = nil
        if let resumed = background.removeValue(forKey: monitor.name) { interval = resumed.interval }
    }

    private func reset() {
        stop()
        isPaused = false
        finished = []
        interval = 0
        checks = []
        rows = []
        events = []
        runs = []
        migratedAt = [:]
        lastRun = nil
        selection = []
    }

    func newSession() {
        detach()
        targetsText = ""
        newText = ""
        oldText = ""
        typeName = "A"
        includeWWW = false
        serverText = Self.defaultServers
        name = nil
        checks = []
        rows = []
        events = []
        runs = []
        migratedAt = [:]
        lastRun = nil
        selection = []
        filter = nil
        problem = nil
        savingName = nil
    }

    func rename(_ old: String, to new: String) {
        guard let monitor = saved.first(where: { $0.name == old }) else { return }
        saved.removeAll { $0.name == old || $0.name == new }
        saved.append(SavedMonitor(name: new, targets: monitor.targets, new: monitor.new, old: monitor.old, server: monitor.server, type: monitor.type, www: monitor.www))
        saved.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        states[new] = states.removeValue(forKey: old)
        background[new] = background.removeValue(forKey: old)
        if name == old { name = new }
    }

    func delete(_ name: String) {
        saved.removeAll { $0.name == name }
        states[name] = nil
        background[name] = nil
        if self.name == name { self.name = nil }
    }
}

struct MonitorState: Codable {
    var checks: [Migration.Check]
    var events: [MonitorEvent]
    var migratedAt: [String: Date]
    var lastRun: Date?
    var runs: [MonitorRun]?

    var isDone: Bool { !checks.isEmpty && checks.allSatisfy { [.migrated, .proxied, .failed].contains($0.status) } }

    func count(_ status: MigrationStatus) -> Int { checks.filter { $0.status == status }.count }

    mutating func record(_ new: [Migration.Check], at now: Date) -> [String] {
        let before = Dictionary(checks.map { ($0.target, $0.status) }, uniquingKeysWith: { a, _ in a })
        checks = new
        lastRun = now
        var migrated: [String] = []
        for check in checks {
            if check.status == .migrated, migratedAt[check.target] == nil { migratedAt[check.target] = now }
            if check.status != .migrated { migratedAt[check.target] = nil }
            guard let previous = before[check.target], previous != check.status else { continue }
            events.insert(MonitorEvent(date: now, domain: check.target, from: previous, to: check.status), at: 0)
            if check.status == .migrated { migrated.append(check.target) }
        }
        events = Array(events.prefix(500))
        runs = Array(((runs ?? []) + [MonitorRun(date: now, counts: Dictionary(grouping: checks, by: \.status.rawValue).mapValues(\.count))]).suffix(500))
        return migrated
    }

    func notify(_ migrated: [String], kind: Migration.Kind, title: String) {
        guard !migrated.isEmpty else { return }
        Notifier.post(migrated.count == 1 ? "\(migrated[0]) has the expected \(kind.name) record" : "\(migrated.count) domains have the expected \(kind.name) record",
                      migrated.count == 1 ? "\(count(.migrated)) of \(checks.count) done in \(title)." : migrated.joined(separator: ", "))
    }

    func notifyDone(title: String) {
        let message = "Every domain in \(title) is checked: \(count(.migrated)) migrated" + (count(.proxied) + count(.failed) > 0 ? ", \(count(.proxied)) proxied, \(count(.failed)) failed." : ".")
        Notifier.post("Migration watch finished", message)
    }
}

struct MonitorRun: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let counts: [String: Int]

    func count(_ status: MigrationStatus) -> Int { counts[status.rawValue] ?? 0 }
}

struct MonitorEvent: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let domain: String
    let from: MigrationStatus
    let to: MigrationStatus
}

struct SavedMonitor: Codable {
    let name: String
    let targets: String
    let new: String
    let old: String
    let server: String
    var type: String?
    var www: Bool?

    var kind: Migration.Kind { type == "DMARC" ? .dmarc : .record(RecordType.lookupOrder.first { $0.description == type } ?? .a) }
    var entries: [Migration.Entry] {
        let entries = Migration.parse(targets, kind: kind)
        return www == true ? Migration.addingWWW(entries) : entries
    }
    var newValues: [String] { Migration.values(new, kind: kind) }
    var oldValues: [String] { Migration.values(old, kind: kind) }

    var lookup: Lookup {
        var options = LookupOptions()
        if case .record(let type) = kind { options.types = type == .a ? [.a, .aaaa] : [type] } else { options.types = []; options.dmarc = true }
        options.reverseLookupAddresses = false
        options.hideAdditional = true
        return Lookup(options: options, servers: (try? Server.list(parsing: server)) ?? [])
    }

    func checks(_ rows: [Row]) -> [Migration.Check] {
        let (new, old) = (newValues, oldValues)
        return entries.map {
            Migration.check($0.target.display, rows: rows, kind: kind, new: $0.expected.isEmpty ? new : $0.expected, old: $0.previous.isEmpty ? old : $0.previous)
        }
    }
}

extension MigrationStatus {
    var color: Color {
        switch self {
        case .migrated: .ok
        case .propagating: .accentText
        case .pending: .warn
        case .unexpected: Color(hex: 0xBF5AF2)
        case .proxied: .cloudflare
        case .failed: .bad
        }
    }

    var symbol: String {
        switch self {
        case .migrated: "checkmark.circle.fill"
        case .propagating: "arrow.triangle.2.circlepath"
        case .pending: "clock"
        case .unexpected: "exclamationmark.triangle.fill"
        case .proxied: "cloud.fill"
        case .failed: "xmark.octagon.fill"
        }
    }

    var help: String {
        switch self {
        case .migrated: "Every server answers with the expected value"
        case .propagating: "Some servers already answer with the expected value, others do not yet"
        case .pending: "No server answers with the expected value yet"
        case .unexpected: "An answer is neither the expected nor the previous value"
        case .proxied: "The answers are Cloudflare IPs, so the origin server cannot be confirmed from DNS"
        case .failed: "No answer of the chosen record type: NXDOMAIN, timeout, or no record"
        }
    }
}

struct StatusPill: View {
    let status: MigrationStatus

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: status.symbol).font(.system(size: 10, weight: .semibold))
            Text(status.rawValue).font(.ui(11.5, .semibold))
        }
        .foregroundStyle(status.color)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Capsule().fill(status.color.opacity(0.15)))
        .help(status.help)
    }
}

struct MonitorView: View {
    @Bindable var session: Session
    private var monitor: Monitor { session.monitor }

    var body: some View {
        if monitor.checks.isEmpty, !monitor.isRunning {
            emptyState
        } else {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    summary
                    Rectangle().fill(Color.white(0.06)).frame(height: 1)
                    MonitorTable(monitor: monitor, session: session)
                    statusBar
                }
                .overlay(alignment: .bottomTrailing) {
                    if session.popover?.inStatusBar == true {
                        ZStack(alignment: .bottomTrailing) {
                            Color.black.opacity(0.001).onTapGesture { session.popover = nil }
                            Group { if session.popover == .monitorLog { log } else { timeline } }
                                .fixedSize()
                                .padding(.trailing, 10)
                                .padding(.bottom, 32)
                        }
                    }
                }
                if let check = monitor.selectedCheck {
                    MonitorDetail(check: check, monitor: monitor, session: session)
                        .frame(width: 320)
                        .background(Color.inspector)
                        .overlay(alignment: .leading) { Rectangle().fill(Color.white(0.08)).frame(width: 1) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.left.arrow.right.circle")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Color.accentText)
                .frame(width: 72, height: 72)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color(hex: 0x201E1D)))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white(0.1)))
                .padding(.bottom, 8)
            Text("Follow a migration").font(.ui(17, .bold))
            Text("Paste the migrated domains and the record they should have, such as the new server's IP. Propagation Checker asks several resolvers and shows which domains already have it.")
                .font(.ui(13))
                .foregroundStyle(Color.white(0.5))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            PrimaryButton(height: 28, radius: 7, action: session.openMonitorSetup) { Text("Set Up…") }
                .padding(.top, 10)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var summary: some View {
        let total = monitor.checks.count
        let migrated = monitor.count(.migrated)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(monitor.isRunning && total == 0 ? "Checking \(monitor.domainCount) domains…" : "\(migrated) of \(total) \(monitor.kind.isAddress ? "point to the new server" : "have the expected \(monitor.kind.name) record")")
                    .font(.ui(15, .bold))
                Spacer()
                if total > 0 { Text("\(Int((Double(migrated) / Double(total) * 100).rounded()))%").font(.ui(13, .semibold)).foregroundStyle(Color.ok).monospacedDigit() }
            }
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(MigrationStatus.allCases, id: \.self) { status in
                        let count = monitor.count(status)
                        if count > 0 { Rectangle().fill(status.color).frame(width: geo.size.width * CGFloat(count) / CGFloat(max(total, 1))) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white(0.08))
                .clipShape(Capsule())
            }
            .frame(height: 6)
            SegmentedBar(segments: [Segment(id: "all", label: "All", count: String(total), on: monitor.filter == nil) { monitor.filter = nil }] +
                MigrationStatus.allCases.map { status in
                    Segment(id: status.rawValue, label: status.rawValue, count: String(monitor.count(status)), help: status.help, on: monitor.filter == status) {
                        monitor.filter = monitor.filter == status ? nil : status
                    }
                })
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if monitor.isRunning { Spinner() }
            Text(statusText).foregroundStyle(Color.t2)
            Spacer(minLength: 0)
            Button { session.popover = session.popover == .monitorTimeline ? nil : .monitorTimeline } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chart.bar.xaxis").font(.system(size: 10))
                    Text(monitor.runs.isEmpty ? "No runs yet" : "\(monitor.runs.count) run\(monitor.runs.count == 1 ? "" : "s")")
                }
                .foregroundStyle(monitor.runs.isEmpty ? Color.t3 : .accentText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { session.popover = session.popover == .monitorLog ? nil : .monitorLog } label: {
                HStack(spacing: 5) {
                    Image(systemName: "list.bullet.rectangle").font(.system(size: 10))
                    Text(monitor.events.isEmpty ? "No status changes yet" : "\(monitor.events.count) status change\(monitor.events.count == 1 ? "" : "s")")
                }
                .foregroundStyle(monitor.events.isEmpty ? Color.t3 : .accentText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .font(.ui(11.5))
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(Color.statusBar)
        .overlay(alignment: .top) { Rectangle().fill(Color.white(0.08)).frame(height: 1) }
    }

    private var timeline: some View {
        Panel(radius: 10, padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    Text("Timeline").font(.ui(12, .bold))
                    Spacer()
                    if !monitor.runs.isEmpty {
                        Button("Export…") { session.exportRuns() }.buttonStyle(.plain).font(.ui(12)).foregroundStyle(Color.accentText)
                        Button("Clear") { monitor.clearRuns() }.buttonStyle(.plain).font(.ui(12)).foregroundStyle(Color.accentText)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                Rectangle().fill(Color.white(0.08)).frame(height: 1)
                if monitor.runs.isEmpty {
                    Text("Each check adds a run with the number of domains in each status.").font(.ui(12)).foregroundStyle(Color.t3).padding(14)
                } else {
                    let shown = MigrationStatus.allCases.filter { status in monitor.runs.contains { $0.count(status) > 0 } }
                    Chart {
                        ForEach(shown, id: \.self) { status in
                            ForEach(monitor.runs) { run in
                                LineMark(x: .value("Run", run.date), y: .value("Domains", run.count(status)), series: .value("Status", status.rawValue))
                                    .foregroundStyle(by: .value("Status", status.rawValue))
                                PointMark(x: .value("Run", run.date), y: .value("Domains", run.count(status)))
                                    .foregroundStyle(by: .value("Status", status.rawValue))
                                    .symbolSize(18)
                            }
                        }
                    }
                    .chartForegroundStyleScale(domain: shown.map(\.rawValue), range: shown.map(\.color))
                    .chartLegend(position: .bottom)
                    .chartXAxis { AxisMarks { AxisGridLine().foregroundStyle(Color.white(0.06)); AxisValueLabel().foregroundStyle(Color.t3) } }
                    .chartYAxis { AxisMarks { AxisGridLine().foregroundStyle(Color.white(0.06)); AxisValueLabel().foregroundStyle(Color.t3) } }
                    .frame(height: 180)
                    .padding(14)
                    if let last = monitor.runs.last {
                        Text("Last run \(last.date.formatted(date: .abbreviated, time: .standard)): \(last.count(.migrated)) of \(last.counts.values.reduce(0, +)) migrated")
                            .font(.ui(11.5)).foregroundStyle(Color.t2).padding(.horizontal, 14).padding(.bottom, 12)
                    }
                }
            }
        }
        .frame(width: 460)
    }

    private var log: some View {
        Panel(radius: 10, padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Status changes").font(.ui(12, .bold))
                    Spacer()
                    if !monitor.events.isEmpty {
                        Button("Clear") { monitor.clearEvents() }.buttonStyle(.plain).font(.ui(12)).foregroundStyle(Color.accentText)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                Rectangle().fill(Color.white(0.08)).frame(height: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if monitor.events.isEmpty {
                            Text("Each check after the first logs the domains whose status changed.").font(.ui(12)).foregroundStyle(Color.t3).padding(14)
                        }
                        ForEach(monitor.events) { event in
                            HStack(spacing: 8) {
                                Text(event.date.formatted(date: .omitted, time: .standard)).font(.ui(11.5)).monospacedDigit().foregroundStyle(Color.white(0.45)).frame(width: 64, alignment: .leading)
                                Text(event.domain).font(.ui(12, .medium)).lineLimit(1)
                                Spacer(minLength: 6)
                                Text(event.from.rawValue).font(.ui(11.5)).foregroundStyle(event.from.color)
                                Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(Color.t3)
                                Text(event.to.rawValue).font(.ui(11.5, .semibold)).foregroundStyle(event.to.color)
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 26)
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
        .frame(width: 400)
    }

    private var statusText: String {
        let servers = (try? Server.list(parsing: monitor.serverText))?.count ?? 0
        var parts = ["\(monitor.domainCount) domain\(monitor.domainCount == 1 ? "" : "s")", servers == 0 ? "system resolver" : "\(servers) server\(servers == 1 ? "" : "s")"]
        if monitor.isRunning { parts.append("checking") } else if monitor.isPaused { parts.append("paused") } else if let last = monitor.lastRun { parts.append("checked at \(last.formatted(date: .omitted, time: .standard))") }
        if monitor.interval > 0, !monitor.isRunning, let next = monitor.nextRun {
            parts.append("next check at \(next.formatted(date: .omitted, time: .standard))")
        }
        if monitor.visibleChecks.count != monitor.checks.count { parts.append("\(monitor.visibleChecks.count) shown") }
        if monitor.leftoverCount > 0 { parts.append("\(monitor.leftoverCount) with AAAA left over") }
        return parts.joined(separator: " · ")
    }
}

struct MonitorTable: View {
    let monitor: Monitor
    let session: Session

    private static let columns: [(String, CGFloat?, CGFloat)] = [("Status", 150, 0), ("Domain", nil, 1.1), ("Expected", nil, 0.9), ("Answers by server", nil, 2), ("TTL", 60, 0), ("Migrated", 92, 0)]

    var body: some View {
        GeometryReader { geo in
            let widths = widths(geo.size.width - 16)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(Array(Self.columns.enumerated()), id: \.offset) { i, column in
                        if shown(column.0) {
                            Text(column.0).padding(.horizontal, 8).frame(width: widths[i], alignment: column.0 == "TTL" || column.0 == "Migrated" ? .trailing : .leading)
                        }
                    }
                }
                .font(.ui(11.5, .semibold))
                .foregroundStyle(Color.white(0.5))
                .frame(height: 28)
                .overlay(alignment: .bottom) { Rectangle().fill(Color.white(0.08)).frame(height: 1) }
                .padding(.horizontal, 8)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(monitor.visibleChecks.enumerated()), id: \.element.target) { k, check in
                            row(check, odd: k % 2 == 1, widths: widths)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func row(_ check: Migration.Check, odd: Bool, widths: [CGFloat]) -> some View {
        let selected = monitor.selection.contains(check.target)
        return HStack(spacing: 0) {
            if shown("Status") {
                HStack(spacing: 5) {
                    StatusPill(status: check.status)
                    if let leftover = check.leftoverAAAA { LeftoverMark(addresses: leftover) }
                }
                .padding(.horizontal, 8)
                .frame(width: widths[0], alignment: .leading)
            }
            Text(check.target).fontWeight(.medium).foregroundStyle(Color.white(0.92)).cell(widths[1])
            if shown("Expected") { Text(check.expected.joined(separator: ", ")).font(.mono(12)).foregroundStyle(Color.t2).cell(widths[2]) }
            if shown("Answers by server") { answers(check).cell(widths[3]) }
            if shown("TTL") { Text(check.ttl.map(String.init) ?? "").font(.mono(12)).foregroundStyle(Color.t2).cell(widths[4], trailing: true) }
            if shown("Migrated") {
                Text(monitor.migratedAt[check.target].map { $0.formatted(date: .omitted, time: .shortened) } ?? "").font(.ui(12)).foregroundStyle(Color.ok).monospacedDigit()
                    .cell(widths[5], trailing: true)
                    .help(monitor.migratedAt[check.target].map { "First seen migrated \($0.formatted(date: .abbreviated, time: .standard))" } ?? "")
            }
        }
        .font(.ui(12))
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accent.opacity(0.32) : odd ? .white(0.025) : .clear))
        .contentShape(Rectangle())
        .onTapGesture {
            if NSEvent.modifierFlags.isDisjoint(with: [.command, .shift]), monitor.selection == [check.target] {
                monitor.selection = []
            } else {
                clickSelect(check.target, in: monitor.visibleChecks.map(\.target), selection: &monitor.selection, anchor: &monitor.selectionAnchor)
            }
        }
        .contextMenu {
            Button("Show Details") { monitor.selection = [check.target] }
            Button("Open in Bulk Lookup") { session.lookUpInResults(check.target) }
            Button("Copy Domain") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(check.target, forType: .string)
            }
        }
    }

    @ViewBuilder private func answers(_ check: Migration.Check) -> some View {
        if let error = check.error {
            Text(error).font(.mono(12)).foregroundStyle(Color.bad)
        } else {
            let groups = Dictionary(grouping: check.answers.keys.sorted()) { Set(check.answers[$0]!) }
                .sorted { $0.value.count > $1.value.count || $0.value.count == $1.value.count && $0.value[0] < $1.value[0] }
            HStack(spacing: 12) {
                ForEach(groups, id: \.value) { ips, servers in
                    let sorted = monitor.ordered(ips, expected: check.expected)
                    HStack(spacing: 5) {
                        Text(sorted.count > 1 ? "\(sorted[0]) +\(sorted.count - 1)" : sorted[0]).foregroundStyle(answerColor(sorted, check: check))
                        Text(groups.count == 1 ? "all \(servers.count)" : servers.joined(separator: ", ")).font(.ui(11)).foregroundStyle(Color.t3)
                    }
                    .help("\(sorted.joined(separator: ", ")) from \(servers.joined(separator: ", "))")
                }
            }
            .font(.mono(11.5))
        }
    }

    private func answerColor(_ answers: [String], check: Migration.Check) -> Color {
        let kinds = Set(answers.map { Migration.classify($0, kind: monitor.kind, new: check.expected, old: check.previous ?? []) })
        if kinds == [.new] { return .ok }
        if kinds == [.old] { return .warn }
        if kinds == [.cloudflare] { return .cloudflare }
        if monitor.kind.isText { return kinds.contains(.new) ? .ok : .t2 }
        return check.status == .unexpected ? MigrationStatus.unexpected.color : .t1
    }

    static let columnNames = columns.map(\.0)

    private func shown(_ column: String) -> Bool { column == "Domain" || !monitor.hiddenColumns.contains(column) }

    private func widths(_ total: CGFloat) -> [CGFloat] {
        let visible = Self.columns.filter { shown($0.0) }
        let fixed = visible.compactMap(\.1).reduce(0, +)
        let fractions = visible.map(\.2).reduce(0, +)
        return Self.columns.map { shown($0.0) ? $0.1 ?? max(80, (total - fixed) * $0.2 / fractions) : 0 }
    }
}

struct LeftoverMark: View {
    let addresses: [String]

    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 11))
            .foregroundStyle(Color.warn)
            .help("AAAA still answers \(addresses.joined(separator: ", ")), which is not an expected IPv6 address, so IPv6 visitors may reach another server")
    }
}

private extension View {
    func cell(_ width: CGFloat, trailing: Bool = false) -> some View {
        lineLimit(1).truncationMode(.tail).padding(.horizontal, 8).frame(width: width, alignment: trailing ? .trailing : .leading)
    }
}

private struct MonitorDetail: View {
    let check: Migration.Check
    let monitor: Monitor
    let session: Session

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(check.target).font(.ui(18, .bold)).textSelection(.enabled)
                    StatusPill(status: check.status)
                    Text(check.status.help).font(.ui(12)).foregroundStyle(Color.white(0.6)).fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                divider
                section("Expected \(monitor.kind.name)") {
                    field("Expected", check.expected.joined(separator: ", "), .ok)
                    field("Previous", (check.previous ?? []).joined(separator: ", "), .warn)
                    field("Lowest TTL", check.ttl.map { "\($0) s" } ?? "", .t1)
                }
                if let leftover = check.leftoverAAAA {
                    divider
                    section("IPv6") {
                        HStack(alignment: .top, spacing: 8) {
                            LeftoverMark(addresses: leftover)
                            Text("AAAA answers that are not an expected IPv6 address. IPv6 visitors may still reach another server; add the new IPv6 address to Expected if it is right.")
                                .font(.ui(12)).foregroundStyle(Color.white(0.6)).fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(leftover, id: \.self) { Text($0).font(.mono(12)).foregroundStyle(Color.warn).textSelection(.enabled) }
                    }
                }
                divider
                section("Answers by server") {
                    if let error = check.error {
                        Text(error).font(.mono(12)).foregroundStyle(Color.bad)
                    }
                    ForEach(check.answers.keys.sorted(), id: \.self) { server in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(server).font(.ui(11.5, .semibold)).foregroundStyle(Color.white(0.6))
                            ForEach(monitor.ordered(check.answers[server]!, expected: check.expected), id: \.self) { ip in
                                HStack(spacing: 6) {
                                    Text(ip).font(.mono(12)).textSelection(.enabled)
                                    Text(label(ip)).font(.ui(11)).foregroundStyle(labelColor(ip))
                                }
                            }
                        }
                    }
                }
                divider
                VStack(alignment: .leading, spacing: 8) {
                    SecondaryButton(title: "Open in Bulk Lookup", height: 26, size: 12.5) { session.lookUpInResults(check.target) }
                    Text("Runs a full lookup of this domain in Bulk Lookup with the same servers.").font(.ui(11)).foregroundStyle(Color.white(0.45))
                }
                .padding(20)
            }
        }
    }

    private var divider: some View { Rectangle().fill(Color.white(0.08)).frame(height: 1) }

    private func answer(_ text: String) -> Migration.Answer {
        Migration.classify(text, kind: monitor.kind, new: check.expected, old: check.previous ?? [])
    }

    private func label(_ text: String) -> String {
        switch answer(text) {
        case .new: "expected"
        case .old: "previous"
        case .cloudflare: "Cloudflare"
        case .other: monitor.kind.isText ? "other record" : "unexpected"
        }
    }

    private func labelColor(_ text: String) -> Color {
        switch answer(text) {
        case .new: .ok
        case .old: .warn
        case .cloudflare: .cloudflare
        case .other: monitor.kind.isText ? .t3 : MigrationStatus.unexpected.color
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.ui(12, .bold))
            content()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private func field(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).foregroundStyle(Color.white(0.5)).frame(width: 84, alignment: .leading)
            Text(value.isEmpty ? "None" : value).font(.mono(12)).foregroundStyle(value.isEmpty ? Color.t3 : color).textSelection(.enabled)
        }
        .font(.ui(12.5))
    }
}

struct MonitorSheet: View {
    @Bindable var session: Session
    @Bindable var monitor: Monitor

    var body: some View {
        SheetPanel {
            HStack(spacing: 8) {
                Text("Domains").font(.ui(13, .bold)).frame(maxWidth: .infinity, alignment: .leading)
                SmallButton(title: "Clear") { monitor.targetsText = ""; monitor.problem = nil }
                    .help("Empty the domain list")
                    .disabled(monitor.targetsText.isEmpty)
                    .opacity(monitor.targetsText.isEmpty ? 0.5 : 1)
                SmallButton(title: "New Session") { monitor.newSession() }
                    .help("Start an unsaved check with no domains, no expected values, and the public resolvers")
                savedButton
                SmallButton(title: "Load from File…") { monitor.importing = true }
            }
            .zIndex(1)
            VStack(alignment: .leading, spacing: 6) {
                TextEditor(text: $monitor.targetsText)
                    .font(.mono(12.5))
                    .lineSpacing(4)
                    .scrollContentBackground(.hidden)
                    .foregroundStyle(Color.white(0.9))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 7)
                    .frame(height: 150)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.field))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white(0.12)))
                    .overlay(alignment: .topLeading) {
                        if monitor.targetsText.isEmpty {
                            Text("One domain per line, or load a CSV of domain, old, new. To give one domain its own values, put them after it:\nexample.com \(example) | previous value")
                                .font(.mono(12.5)).foregroundStyle(Color.white(0.3)).padding(.horizontal, 11).padding(.vertical, 9).allowsHitTesting(false)
                        }
                    }
                    .onChange(of: monitor.targetsText) { monitor.problem = nil }
                Text(hint).font(.ui(11.5)).foregroundStyle(Color.white(0.45))
            }
            VStack(alignment: .leading, spacing: 8) {
                field("Server", "Leave empty to use local config, or separate servers by commas", $monitor.serverText)
                HStack(spacing: 6) { ServerPresets(text: $monitor.serverText) { monitor.problem = nil } }
                    .padding(.leading, 108)
            }
            VStack(alignment: .leading, spacing: 10) {
                field("Expected", expectedPrompt, $monitor.newText)
                field("Previous", "Optional: the old value, to tell old answers from unexpected ones", $monitor.oldText)
                if let problem = monitor.problem {
                    Text(problem).font(.ui(12)).foregroundStyle(Color.problem).padding(.leading, 108)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    formLabel("Record type").padding(.top, 3)
                    Text("Pick one").font(.ui(11.5)).foregroundStyle(Color.white(0.45))
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                    ForEach(Monitor.typeNames, id: \.self) { name in
                        TypeChip(label: name, on: monitor.typeName == name) { monitor.typeName = name; monitor.problem = nil }
                    }
                }
            }
            HStack(alignment: .top, spacing: 12) {
                formLabel("Options")
                VStack(alignment: .leading, spacing: 7) {
                    Checkbox(label: "Also check the www. name of each domain", on: monitor.includeWWW, size: 12.5) { monitor.includeWWW.toggle() }
                    if monitor.kind == .record(.a) {
                        Text("A checks also look up AAAA and warn about IPv6 answers that are not in Expected.")
                            .font(.ui(11.5)).foregroundStyle(Color.white(0.45)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } footer: {
            if let name = monitor.savingName {
                TextField("Check name", text: Binding { name } set: { monitor.savingName = $0 })
                    .textFieldStyle(.plain)
                    .font(.ui(12.5))
                    .fieldStyle(focused: true)
                    .frame(width: 180)
                    .onSubmit(save)
                SecondaryButton(title: "Save", action: save)
            } else {
                HoverButton(action: { monitor.savingName = monitor.name ?? "" }, hover: .accent.opacity(0.12), radius: 6) {
                    Text("Save Check…").font(.ui(13)).foregroundStyle(Color.accentText).padding(.horizontal, 12).frame(height: 26)
                }
            }
            Spacer()
            SecondaryButton(title: "Cancel") { session.closeOverlays() }
            PrimaryButton(action: start) {
                HStack(spacing: 8) {
                    Text("Check Now")
                    Text("⌘↩").font(.ui(11)).opacity(0.7)
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
        }
        .fileImporter(isPresented: $monitor.importing, allowedContentTypes: [.plainText, .commaSeparatedText], onCompletion: load)
    }

    private var hint: String {
        let entries = monitor.entries
        guard !entries.isEmpty else { return "Lines starting with # are ignored." }
        let own = entries.filter { !$0.expected.isEmpty || !$0.previous.isEmpty }.count
        return "\(entries.count) domain\(entries.count == 1 ? "" : "s")" + (own == 0 ? "" : " · \(own) with their own value")
    }

    private var example: String {
        switch monitor.kind {
        case .record(.a): "203.0.113.20"
        case .record(.aaaa): "2001:db8::20"
        case .record(.mx): "mx1.newhost.com"
        case .record(.ns): "ns1.newhost.com"
        case .record(.cname): "app.newhost.com"
        case _ where monitor.kind.isText: "include:_spf.newhost.com"
        default: "value"
        }
    }

    private var expectedPrompt: String {
        switch monitor.kind {
        case .record(.a): "IPv4 addresses of the new server, plus IPv6 to check AAAA"
        case .record(.aaaa): "IPv6 addresses of the new server, separated by commas"
        case _ where monitor.kind.isHost: "Host names, such as \(example), separated by commas"
        case _ where monitor.kind.isText: "Text the record must contain; separate several with commas"
        default: "Record data as Bulk Lookup shows it, separated by commas"
        }
    }

    private func field(_ label: String, _ prompt: String, _ text: Binding<String>) -> some View {
        HStack(spacing: 12) {
            formLabel(label)
            TextField(prompt, text: text)
                .textFieldStyle(.plain)
                .font(.mono(12))
                .foregroundStyle(Color.white(0.9))
                .fieldStyle()
                .onChange(of: text.wrappedValue) { monitor.problem = nil }
        }
    }

    private var savedButton: some View {
        HoverButton(action: { monitor.showingSavedMenu.toggle() }, normal: .white(0.1), hover: .white(0.14), radius: 6) {
            HStack(spacing: 6) {
                Text(monitor.name ?? "Saved Checks")
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Color.white(0.6))
            }
            .font(.ui(12))
            .foregroundStyle(Color.t1)
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .frame(height: 24)
        }
        .overlay(alignment: .topTrailing) {
            if monitor.showingSavedMenu {
                Panel(background: .menu) {
                    VStack(alignment: .leading, spacing: 0) {
                        if monitor.saved.isEmpty {
                            Text("No saved checks").font(.ui(13)).foregroundStyle(Color.t3).padding(.horizontal, 9).frame(height: 24)
                        }
                        ForEach(monitor.saved, id: \.name) { saved in
                            MenuItem(label: saved.name) {
                                monitor.load(saved)
                                monitor.showingSavedMenu = false
                            }
                        }
                    }
                }
                .frame(width: 200)
                .offset(y: 28)
            }
        }
    }

    private func load(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            monitor.targetsText = url.pathExtension.lowercased() == "csv" ? Migration.lines(fromCSV: text) : text
        } catch {
            monitor.problem = error.localizedDescription
        }
    }

    private func start() {
        if let problem = monitor.problemText() {
            monitor.problem = problem
            return
        }
        monitor.savingName = nil
        session.closeOverlays()
        monitor.run()
    }

    private func save() {
        guard let name = monitor.savingName?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return }
        monitor.save(as: name)
        monitor.savingName = nil
        session.flash("Saved \u{201C}\(name)\u{201D}")
    }
}
