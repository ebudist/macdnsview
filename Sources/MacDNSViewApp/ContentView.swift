import AppKit
import MacDNSViewCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var session: Session

    var body: some View {
        NavigationSplitView {
            Sidebar(session: session)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            switch session.pane {
            case .results: ResultsView(session: session)
            case .watch: WatchView(session: session)
            case .history: HistoryView(session: session)
            }
        }
        .sheet(isPresented: $session.showingSheet) { TargetsSheet(session: session) }
        .sheet(isPresented: $session.showingExport) { ExportSheet(session: session) }
    }
}

private enum SidebarItem: Hashable {
    case pane(Pane)
    case list(String)
}

private struct Sidebar: View {
    @Bindable var session: Session

    var body: some View {
        List(selection: Binding<SidebarItem?> { .pane(session.pane) } set: { item in
            switch item {
            case .pane(let pane): session.pane = pane
            case .list(let name): session.runList(name)
            case nil: break
            }
        }) {
            SwiftUI.Section("Lookup") {
                Label("Results", systemImage: "list.bullet")
                    .badge(session.rows.isEmpty ? 0 : session.rows.count)
                    .tag(SidebarItem.pane(.results))
                Label("Watch", systemImage: "waveform.path.ecg")
                    .badge(session.autoRefresh == 0 ? nil : Text(intervalName(session.autoRefresh)).foregroundStyle(.green))
                    .tag(SidebarItem.pane(.watch))
                Label("History", systemImage: "clock.arrow.circlepath")
                    .tag(SidebarItem.pane(.history))
            }
            SwiftUI.Section {
                ForEach(session.savedLists, id: \.name) { list in
                    Label(list.name, systemImage: "bookmark")
                        .badge(Target.parse(list.targets, extractHostFromURL: list.options.extractHostFromURL).count)
                        .tag(SidebarItem.list(list.name))
                        .contextMenu {
                            Button("Rename…") {
                                if let name = askName("Rename \(list.name) to", initial: list.name, button: "Rename") {
                                    session.renameList(list.name, to: name)
                                }
                            }
                            Button("Delete", role: .destructive) { session.deleteList(list.name) }
                        }
                }
            } header: {
                HStack {
                    Text("Saved Lists")
                    Spacer()
                    Button { session.newList() } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("New list")
                }
            }
        }
        .listStyle(.sidebar)
    }
}

func intervalName(_ seconds: Int) -> String { seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m" }

@MainActor func askName(_ message: String, initial: String, button: String) -> String? {
    let alert = NSAlert()
    alert.messageText = message
    let field = NSTextField(string: initial)
    field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
    alert.accessoryView = field
    alert.addButton(withTitle: button)
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let name = field.stringValue.trimmingCharacters(in: .whitespaces)
    return name.isEmpty ? nil : name
}

struct ResultsView: View {
    @Bindable var session: Session

    var body: some View {
        VStack(spacing: 0) {
            if !session.rows.isEmpty || session.isRunning { filterBar }
            table
                .overlay {
                    if session.rows.isEmpty, !session.isRunning {
                        ContentUnavailableView {
                            Label("No lookups yet", systemImage: "network")
                        } description: {
                            Text("Paste domains, IP addresses, or URLs, or drop a text file here.")
                        } actions: {
                            Button("Look Up…") { session.showingSheet = true }
                                .buttonStyle(.borderedProminent)
                        }
                    } else if !session.rows.isEmpty, session.visibleRows.isEmpty {
                        // A leftover search or result filter otherwise makes a finished lookup look empty.
                        ContentUnavailableView {
                            Label(session.search.isEmpty ? "No rows with the chosen results" : "No rows match \u{201C}\(session.search)\u{201D}",
                                  systemImage: "magnifyingglass")
                        } actions: {
                            if !session.search.isEmpty { Button("Clear Search") { session.search = "" } }
                            Button("Show All Results") { session.showAllResults() }
                        }
                    }
                }
                .overlay(alignment: .top) {
                    if session.isRunning {
                        ProgressView(value: session.progress).progressViewStyle(.linear).controlSize(.mini)
                    }
                }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { statusLine }
        .inspector(isPresented: $session.showingInspector) {
            InspectorView(session: session).inspectorColumnWidth(min: 260, ideal: 320)
        }
        .toolbar { toolbar }
        .navigationTitle(session.currentList ?? "Results")
        .navigationSubtitle(subtitle)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, (try? session.load(url)) != nil else { return false }
            session.run()
            return true
        }
        .onCopyCommand { [NSItemProvider(object: export(session.selectedRows, as: .tsv) as NSString)] }
    }

    private var subtitle: String {
        guard !session.targetsText.isEmpty else { return "Look up DNS records for many names at once" }
        let targets = Target.parse(session.targetsText, extractHostFromURL: session.options.extractHostFromURL).count
        let types = RecordType.lookupOrder.filter(session.options.types.contains).map(\.description) + (session.options.dmarc ? ["DMARC"] : [])
        let server = session.serverText.trimmingCharacters(in: .whitespaces)
        return "\(targets) targets · \(types.joined(separator: ", ")) · \(server.isEmpty ? "System resolver" : server)"
    }

    private var filterBar: some View {
        let counts = Dictionary(grouping: session.rows, by: \.outcome).mapValues(\.count)
        let differs = session.rows.filter { $0.differs == true }.count
        return HStack(spacing: 16) {
            Picker("Results", selection: Binding<Outcome?> {
                session.outcomes.count == Outcome.allCases.count ? nil : session.outcomes.count == 1 ? session.outcomes.first : .none
            } set: {
                session.outcomes = $0.map { [$0] } ?? Set(Outcome.allCases)
            }) {
                Text("All \(session.rows.count)").tag(Outcome?.none)
                ForEach(Outcome.allCases, id: \.self) { Text("\($0.rawValue) \(counts[$0] ?? 0)").tag(Outcome?.some($0)) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Toggle(isOn: $session.onlyDiffers) {
                HStack(spacing: 4) {
                    Text("Differs")
                    if differs > 0 { Text(String(differs)).foregroundStyle(.orange).monospacedDigit() }
                }
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help("Only rows where servers differ")
            HStack(spacing: 6) {
                Image(systemName: "cloud.fill").foregroundStyle(Color.cloudflare)
                Text("Cloudflare")
                Picker("Cloudflare", selection: $session.cloudflareFilter) {
                    ForEach(CloudflareFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .help("Cloudflare: matched against cloudflare.com/ips and *.ns.cloudflare.com")
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var table: some View {
        Table(session.tableRows, selection: $session.selection, sortOrder: $session.sortOrder, columnCustomization: $session.columns) {
            TableColumn("#", value: \.index) { indexCell($0) }
                .width(min: 40, ideal: 54).customizationID("index")
            TableColumn("Target", value: \.target) { cell($0.target, $0).fontWeight(.medium) }
                .width(min: 80, ideal: 160).customizationID("target")
            TableColumn("Type", value: \.typeName) { cell($0.typeName, $0).monospaced() }
                .width(min: 50, ideal: 56).customizationID("type")
            TableColumn("Name", value: \.name) { cell($0.name, $0).monospaced() }
                .width(min: 80, ideal: 200).customizationID("name")
            TableColumn("Address", value: \.address) { cell($0.address, $0).monospaced() }
                .width(min: 60, ideal: 130).customizationID("address")
            TableColumn("Data", value: \.data) { cell($0.data, $0).monospaced() }
                .width(min: 80, ideal: 280).customizationID("data")
            TableColumn("Section", value: \.sectionName) { cell($0.sectionName, $0) }
                .width(min: 50, ideal: 70).customizationID("section")
            // The column builder takes at most 10 children.
            Group {
                TableColumn("TTL", value: \.ttlSortValue) { cell($0.ttl.map(String.init) ?? "", $0).monospacedDigit() }
                    .width(min: 44, ideal: 58).customizationID("ttl")
                TableColumn("Server", value: \.server) { cell($0.server, $0).monospaced() }
                    .width(min: 60, ideal: 100).customizationID("server")
                TableColumn("Time", value: \.timeSortValue) { row in
                    cell(row.time.map { "\($0) ms" } ?? "", row).monospacedDigit()
                        .foregroundStyle((row.time ?? 0) > 50 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
                .width(min: 50, ideal: 60).customizationID("time")
                TableColumn("DNSSEC", value: \.validatedName) { row in
                    if row.validated == true {
                        Image(systemName: "checkmark").foregroundStyle(.green).fontWeight(.semibold)
                    } else {
                        cell(row.validatedName, row).foregroundStyle(.tertiary)
                    }
                }
                .width(min: 50, ideal: 62).customizationID("validated")
                TableColumn("Differs", value: \.differsName) { row in
                    Text(row.differs == true ? "yes" : "").foregroundStyle(.orange).fontWeight(.semibold)
                }
                .width(min: 44, ideal: 58).customizationID("differs")
            }
        }
        .contextMenu(forSelectionType: Row.ID.self) { ids in
            if !ids.isEmpty {
                Button("Copy") { copy(session.visibleRows.filter { ids.contains($0.id) }) }
            }
        }
    }

    private func copy(_ rows: [Row]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(export(rows, as: .tsv), forType: .string)
    }

    private func cell(_ text: String, _ row: Row) -> Text {
        if session.removed.contains(where: { $0.id == row.id }) { return Text(text).strikethrough().foregroundStyle(.secondary) }
        return Text(text).foregroundStyle(row.outcome == .ok ? AnyShapeStyle(.primary) : AnyShapeStyle(row.outcome.color))
    }

    private func indexCell(_ row: Row) -> some View {
        HStack(spacing: 4) {
            Text(String(row.index)).monospacedDigit().foregroundStyle(.tertiary)
            if session.changed.contains(row.id) {
                Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.blue).help("New or changed since the last run")
            } else if session.removed.contains(where: { $0.id == row.id }) {
                Image(systemName: "minus.circle.fill").font(.system(size: 9)).foregroundStyle(.secondary).help("Gone since the last run")
            }
            switch Cloudflare.match(row) {
            case .range(let cidr): Image(systemName: "cloud.fill").foregroundStyle(Color.cloudflare).help("Cloudflare IP range \(cidr)")
            case .nameserver: Image(systemName: "cloud.fill").foregroundStyle(Color.cloudflare).help("Cloudflare nameserver")
            case nil: EmptyView()
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search records", text: $session.search)
                .textFieldStyle(.plain)
                .onExitCommand { session.search = "" }
            if !session.search.isEmpty {
                Button { session.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear the search")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.6)))
        .frame(width: 200)
    }

    private static let columnNames = [("# (row)", "index"), ("Target", "target"), ("Type", "type"), ("Name", "name"), ("Address", "address"),
                                      ("Data", "data"), ("Section", "section"), ("TTL", "ttl"), ("Server", "server"), ("Time", "time"), ("DNSSEC", "validated"), ("Differs", "differs")]

    private var filterMenu: some View {
        Button { session.showingFilter.toggle() } label: {
            Label("Filter", systemImage: session.isFiltered || !session.showRemoved ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .help("Choose which results and columns to show")
        .popover(isPresented: $session.showingFilter, arrowEdge: .bottom) {
            HStack(alignment: .top, spacing: 24) {
                checklist("Results", Outcome.allCases.map { outcome in
                    (outcome.rawValue, Binding { session.outcomes.contains(outcome) } set: {
                        if $0 { session.outcomes.insert(outcome) } else { session.outcomes.remove(outcome) }
                    })
                } + [("Gone since the last run", $session.showRemoved), ("Only rows where servers differ", $session.onlyDiffers)])
                checklist("Columns", Self.columnNames.map { name, id in
                    (name, Binding { session.columns[visibility: id] != .hidden } set: { session.columns[visibility: id] = $0 ? .visible : .hidden })
                }, columns: 2)
            }
            .padding(14)
        }
    }

    private func checklist(_ title: String, _ items: [(String, Binding<Bool>)], columns: Int = 1) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if columns > 1 {
                    Button("Show All") { for item in items { item.1.wrappedValue = true } }
                        .buttonStyle(.link)
                        .disabled(items.allSatisfy { $0.1.wrappedValue })
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: columns), alignment: .leading, spacing: 6) {
                ForEach(items.indices, id: \.self) { Toggle(items[$0].0, isOn: items[$0].1).toggleStyle(.checkbox) }
            }
        }
        .frame(minWidth: columns > 1 ? 200 : 0)
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            if session.isRunning { ProgressView().controlSize(.small) }
            statusText
            Spacer()
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private var statusText: Text {
        let rows = session.rows
        var parts: [(String, Color?)] = [("\(rows.count) rows", nil)]
        for outcome in Outcome.allCases {
            let count = rows.filter { $0.outcome == outcome }.count
            if count > 0 { parts.append(("\(count) \(outcome == .failed ? outcome.rawValue.lowercased() : outcome.rawValue)", outcome.color)) }
        }
        if session.isFiltered { parts.append(("\(session.visibleRows.count) shown", nil)) }
        let cloudflare = session.cloudflareTargets.count
        if cloudflare > 0 { parts.append(("\(cloudflare) target\(cloudflare == 1 ? "" : "s") on Cloudflare", .cloudflare)) }
        if !session.selection.isEmpty { parts.append(("\(session.selection.count) selected", nil)) }
        if session.isRunning { parts.append(("looking up \(session.targetCount) targets", .blue)) }
        if !session.changed.isEmpty || !session.removed.isEmpty {
            parts.append(("\(session.changed.count) changed, \(session.removed.count) removed since the last run", .blue))
        }
        if session.autoRefresh > 0, let finished = session.finishedAt {
            parts.append(("updated \(finished.formatted(date: .omitted, time: .standard))", nil))
        }
        if session.wasStopped { parts.append(("stopped after \(Set(rows.map(\.target)).count) of \(session.targetCount) targets", .orange)) }
        return parts.enumerated().reduce(Text("")) { text, part in
            let (i, (string, color)) = part
            let piece = Text(string).foregroundStyle(color.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
            return i == 0 ? piece : Text("\(text)\(Text(" · ").foregroundStyle(.tertiary))\(piece)")
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem {
            Button { session.showingSheet = true } label: { Label("Look Up", systemImage: "globe") }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.borderedProminent)
                .help("Targets and options (⌘K)")
        }
        ToolbarItemGroup {
            if session.isRunning {
                Button { session.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .foregroundStyle(.red)
                    .help("Stop (⌘.)")
            } else {
                Button { session.run() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Look up the same Targets again (⌘R)")
                    .disabled(session.targetsText.isEmpty)
            }
            Menu {
                Picker("Auto Refresh", selection: $session.autoRefresh) {
                    ForEach(Session.intervals, id: \.seconds) { Text($0.menu).tag($0.seconds) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Auto Refresh", systemImage: session.autoRefresh > 0 ? "timer.circle.fill" : "timer")
            }
            .help("Auto refresh")
            .disabled(session.targetsText.isEmpty)
            Button { session.showingExport = true } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .help("Export (⌘S)")
                .disabled(session.rows.isEmpty)
            filterMenu
        }
        ToolbarItem { searchField }
        ToolbarItem {
            Button { session.showingInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                .help("Inspector (⌘I)")
        }
    }
}

extension Color {
    static let cloudflare = Color(red: 0.953, green: 0.502, blue: 0.125)
}

extension Row {
    var typeName: String { type.description }
    var sectionName: String { section?.rawValue ?? "" }
    var ttlSortValue: Int { ttl.map(Int.init) ?? -1 }
    var timeSortValue: Int { time ?? -1 }
    var validatedName: String { validated.map { $0 ? "yes" : "no" } ?? "" }
    var differsName: String { differs.map { $0 ? "yes" : "no" } ?? "" }
}

/// @FocusState does not reach views in a macOS toolbar, so Find makes the AppKit field first responder.
@MainActor func focusSearch() {
    guard let window = NSApp.keyWindow, let root = window.contentView?.superview else { return }
    func find(_ view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable, field.placeholderString == "Search records" { return field }
        return view.subviews.lazy.compactMap(find).first
    }
    if let field = find(root) { window.makeFirstResponder(field) }
}
