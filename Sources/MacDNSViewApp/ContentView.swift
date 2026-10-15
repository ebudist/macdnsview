import AppKit
import MacDNSViewCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var session: Session

    var body: some View {
        table
            .overlay {
                if session.rows.isEmpty, !session.isRunning {
                    ContentUnavailableView {
                        Label("No lookups yet", systemImage: "network")
                    } description: {
                        Text("Paste domains, IP addresses, or URLs, or drop a text file here.")
                    } actions: {
                        Button("Look Up…") { session.showingSheet = true }
                    }
                } else if !session.rows.isEmpty, session.visibleRows.isEmpty {
                    // A leftover search or result filter otherwise makes a finished lookup look empty.
                    ContentUnavailableView {
                        Label(session.search.isEmpty ? "No rows with the chosen results" : "No rows match \u{201C}\(session.search)\u{201D}",
                              systemImage: "magnifyingglass")
                    } actions: {
                        if !session.search.isEmpty { Button("Clear Search") { session.search = "" } }
                        if session.outcomes.count < Outcome.allCases.count { Button("Show All Results") { session.outcomes = Set(Outcome.allCases) } }
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { statusLine }
            .inspector(isPresented: $session.showingInspector) { inspector.inspectorColumnWidth(min: 240, ideal: 300) }
            .toolbar { toolbar }
            .sheet(isPresented: $session.showingSheet) { TargetsSheet(session: session) }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first, (try? session.load(url)) != nil else { return false }
                session.run()
                return true
            }
            .onCopyCommand { [NSItemProvider(object: export(session.selectedRows, as: .tsv) as NSString)] }
    }

    private var table: some View {
        Table(session.visibleRows, selection: $session.selection, sortOrder: $session.sortOrder, columnCustomization: $session.columns) {
            TableColumn("#", value: \.index) { Text(String($0.index)).monospacedDigit().foregroundStyle(.secondary) }
                .width(min: 30, ideal: 40).customizationID("index")
            TableColumn("Target", value: \.target) { cell($0.target, $0) }
                .width(min: 80, ideal: 160).customizationID("target")
            TableColumn("Type", value: \.typeName) { cell($0.typeName, $0) }
                .width(min: 60, ideal: 64).customizationID("type")
            TableColumn("Name", value: \.name) { cell($0.name, $0) }
                .width(min: 80, ideal: 200).customizationID("name")
            TableColumn("Address", value: \.address) { cell($0.address, $0) }
                .width(min: 60, ideal: 130).customizationID("address")
            TableColumn("Data", value: \.data) { cell($0.data, $0) }
                .width(min: 80, ideal: 280).customizationID("data")
            TableColumn("Section", value: \.sectionName) { cell($0.sectionName, $0) }
                .width(min: 50, ideal: 80).customizationID("section")
            // The column builder takes at most 10 children.
            Group {
                TableColumn("TTL", value: \.ttlSortValue) { cell($0.ttl.map(String.init) ?? "", $0).monospacedDigit() }
                    .width(min: 56, ideal: 64).customizationID("ttl")
                TableColumn("Server", value: \.server) { cell($0.server, $0) }
                    .width(min: 60, ideal: 110).customizationID("server")
                TableColumn("Time", value: \.timeSortValue) { cell($0.time.map { "\($0) ms" } ?? "", $0).monospacedDigit() }
                    .width(min: 50, ideal: 64).customizationID("time")
                TableColumn("Validated", value: \.validatedName) { cell($0.validatedName, $0) }
                    .width(min: 50, ideal: 64).customizationID("validated")
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
        Text(text).foregroundStyle(row.outcome == .ok ? AnyShapeStyle(.primary) : AnyShapeStyle(row.outcome.color))
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $session.search)
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
        .frame(width: 220)
    }

    private static let columnNames = [("#", "index"), ("Target", "target"), ("Type", "type"), ("Name", "name"), ("Address", "address"),
                                      ("Data", "data"), ("Section", "section"), ("TTL", "ttl"), ("Server", "server"), ("Time", "time"), ("Validated", "validated")]

    private var filterMenu: some View {
        let filtered = session.outcomes.count < Outcome.allCases.count
        return Button { session.showingFilter.toggle() } label: {
            Label("Filter", systemImage: filtered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .help("Choose which results and columns to show")
        .popover(isPresented: $session.showingFilter, arrowEdge: .bottom) {
            HStack(alignment: .top, spacing: 24) {
                checklist("Results", Outcome.allCases.map { outcome in
                    (outcome.rawValue, Binding { session.outcomes.contains(outcome) } set: {
                        if $0 { session.outcomes.insert(outcome) } else { session.outcomes.remove(outcome) }
                    })
                })
                checklist("Columns", Self.columnNames.map { name, id in
                    (name, Binding { session.columns[visibility: id] != .hidden } set: { session.columns[visibility: id] = $0 ? .visible : .hidden })
                })
            }
            .padding(12)
        }
    }

    private func checklist(_ title: String, _ items: [(String, Binding<Bool>)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            ForEach(items.indices, id: \.self) { Toggle(items[$0].0, isOn: items[$0].1).toggleStyle(.checkbox) }
            Divider()
            Button("Show All") { for item in items { item.1.wrappedValue = true } }
                .disabled(items.allSatisfy { $0.1.wrappedValue })
        }
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            if session.isRunning { ProgressView().controlSize(.small) }
            statusText
            if session.isRunning {
                Button { session.stop() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Stop the running lookups (⌘.)")
            }
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private var statusText: Text {
        let rows = session.rows
        var parts: [(String, Color?)] = [("\(rows.count) rows", nil)]
        for outcome in Outcome.allCases {
            let count = rows.filter { $0.outcome == outcome }.count
            if count > 0 { parts.append(("\(count) \(outcome == .noData ? outcome.rawValue : outcome.rawValue.lowercased())", outcome.color)) }
        }
        if session.isFiltered { parts.append(("\(session.visibleRows.count) shown", nil)) }
        if !session.selection.isEmpty { parts.append(("\(session.selection.count) selected", nil)) }
        if session.isRunning { parts.append(("looking up \(session.targetCount) targets", nil)) }
        if session.wasStopped { parts.append(("stopped after \(Set(rows.map(\.target)).count) of \(session.targetCount) targets", nil)) }
        return parts.enumerated().reduce(Text("")) { text, part in
            let (i, (string, color)) = part
            let piece = Text(string).foregroundStyle(color.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
            return i == 0 ? piece : Text("\(text)\(Text(", ").foregroundStyle(.secondary))\(piece)")
        }
    }

    @ViewBuilder private var inspector: some View {
        if let row = session.selectedRows.first, session.selection.count == 1 {
            Form {
                ForEach(Array(zip(Row.columns, row.fields)), id: \.0) { label, value in
                    LabeledContent(label) { Text(value).textSelection(.enabled) }
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView(session.selection.isEmpty ? "No selection" : "\(session.selection.count) rows selected", systemImage: "sidebar.right")
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button { session.showingSheet = true } label: { Label("Look Up", systemImage: "network") }
                .labelStyle(.titleAndIcon)
                .help("Targets and options (⌘K)")
            if session.isRunning {
                Button { session.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .help("Stop the running lookups (⌘.)")
            } else {
                Button { session.run() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Look up the same Targets again (⌘R)")
                    .disabled(session.targetsText.isEmpty)
            }
            Button { exportRows(session) } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .help("Export the selected rows, or all rows (⌘S)")
                .disabled(session.rows.isEmpty)
            Button { session.showingInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                .help("Show every field of the selected row (⌘I)")
        }
        ToolbarItem { filterMenu }
        ToolbarItem { searchField }
    }
}

/// The format follows the file extension the user picks; plain text gets the aligned table.
@MainActor func exportRows(_ session: Session) {
    guard !session.rows.isEmpty else { return }
    let rows = session.selectedRows.isEmpty ? session.visibleRows : session.selectedRows
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "macdnsview.csv"
    panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .json, .html, .plainText]
    panel.allowsOtherFileTypes = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let format: ExportFormat = switch url.pathExtension.lowercased() {
    case "csv": .csv
    case "tsv", "tab": .tsv
    case "json": .json
    case "html", "htm": .html
    default: .table
    }
    do {
        try export(rows, as: format).write(to: url, atomically: true, encoding: .utf8)
    } catch {
        NSAlert(error: error).runModal()
    }
}

extension Row {
    var typeName: String { type.description }
    var sectionName: String { section?.rawValue ?? "" }
    var ttlSortValue: Int { ttl.map(Int.init) ?? -1 }
    var timeSortValue: Int { time ?? -1 }
    var validatedName: String { validated.map { $0 ? "yes" : "no" } ?? "" }
}

/// @FocusState does not reach views in a macOS toolbar, so Find makes the AppKit field first responder.
@MainActor func focusSearch() {
    guard let window = NSApp.keyWindow, let root = window.contentView?.superview else { return }
    func find(_ view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable, field.placeholderString == "Search" { return field }
        return view.subviews.lazy.compactMap(find).first
    }
    if let field = find(root) { window.makeFirstResponder(field) }
}
