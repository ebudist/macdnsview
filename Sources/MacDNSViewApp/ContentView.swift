import AppKit
import MacDNSViewCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var session: Session

    var body: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                if session.showingSidebar {
                    Sidebar(session: session)
                        .frame(width: 216)
                        .background(Color.sidebar)
                        .overlay(alignment: .trailing) { Rectangle().fill(.black.opacity(0.55)).frame(width: 1) }
                }
                VStack(spacing: 0) {
                    Header(session: session).zIndex(1)
                    HStack(spacing: 0) {
                        Group {
                            switch session.pane {
                            case .results: ResultsView(session: session)
                            case .watch: WatchView(session: session)
                            case .history: HistoryView(session: session)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .zIndex(1)
                        if session.pane == .results, session.showingInspector, !session.rows.isEmpty || session.isRunning {
                            InspectorView(session: session)
                                .frame(width: 320)
                                .background(Color.inspector)
                                .overlay(alignment: .leading) { Rectangle().fill(Color.white(0.08)).frame(width: 1) }
                        }
                    }
                    .overlay {
                        if session.popover != nil {
                            Color.black.opacity(0.001).onTapGesture { session.popover = nil }
                        }
                    }
                }
            }
            if session.showingSheet || session.showingExport {
                Color.black.opacity(0.38)
                    .onTapGesture { session.closeOverlays() }
                Group {
                    if session.showingSheet { TargetsSheet(session: session).frame(width: 640) }
                    if session.showingExport { ExportSheet(session: session).frame(width: 580) }
                }
                .padding(.top, 36)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let toast = session.toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.ui(12.5))
                        .foregroundStyle(Color.white(0.92))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.toast))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white(0.12)))
                        .shadow(color: .black.opacity(0.5), radius: 15, y: 10)
                        .padding(.bottom, 44)
                }
                .transition(.opacity)
            }
            if session.showingSheet || session.showingExport || session.popover != nil {
                Button("") { session.closeOverlays() }.keyboardShortcut(.cancelAction).hidden()
            } else if session.pane == .results {
                Button("") { session.select(offset: 1) }.keyboardShortcut(.downArrow, modifiers: []).hidden()
                Button("") { session.select(offset: -1) }.keyboardShortcut(.upArrow, modifiers: []).hidden()
            }
        }
        .animation(.easeOut(duration: 0.16), value: session.showingSheet || session.showingExport)
        .animation(.easeOut(duration: 0.15), value: session.toast)
        .font(.ui(13))
        .foregroundStyle(Color.t1)
        .background(Color.window)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .background(WindowChrome())
        .fileImporter(isPresented: $session.importing, allowedContentTypes: [.plainText, .commaSeparatedText]) { result in
            if case .success(let url) = result {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do { try session.load(url) } catch { session.problem = error.localizedDescription }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, (try? session.load(url)) != nil else { return false }
            session.run()
            return true
        }
        .onCopyCommand { [NSItemProvider(object: export(session.selectedRows, as: .tsv) as NSString)] }
    }

}

private struct Sidebar: View {
    @Bindable var session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Spacer()
                IconButton(symbol: "sidebar.left", color: .white(0.5), size: 14, width: 24, height: 22, help: "Hide sidebar") {
                    session.showingSidebar = false
                }
            }
            .frame(height: 52)
            .padding(.trailing, 2)
            heading("Lookup").padding(.top, 4)
            item("Results", "list.bullet", .results, badge: session.rows.isEmpty ? nil : String(session.rows.count))
            item("Watch", "waveform.path.ecg", .watch, badge: session.autoRefresh == 0 ? nil : intervalName(session.autoRefresh), live: true)
            item("History", "clock.arrow.circlepath", .history, badge: nil)
            HStack {
                heading("Saved Lists")
                Spacer()
                IconButton(symbol: "plus", color: .white(0.5), size: 11, width: 20, height: 20, help: "New list") { session.newList() }
            }
            .padding(.top, 12)
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(session.savedLists, id: \.name) { list in savedList(list) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.ui(11, .semibold)).foregroundStyle(Color.white(0.35)).padding(.horizontal, 8).padding(.vertical, 4)
    }

    private func item(_ label: String, _ symbol: String, _ pane: Pane, badge: String?, live: Bool = false) -> some View {
        let on = session.pane == pane
        return HoverButton(action: { session.pane = pane; session.popover = nil }, normal: on ? .accent.opacity(0.2) : .clear,
                           hover: on ? .accent.opacity(0.26) : .white(0.06), radius: 6) {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(on ? Color.accentText : .t2).frame(width: 16)
                Text(label).foregroundStyle(on ? Color.accentText : .t1)
                Spacer(minLength: 0)
                if let badge {
                    Text(badge)
                        .font(.ui(11, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(live ? Color.ok : .t2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(live ? Color.ok.opacity(0.2) : .white(0.1)))
                }
            }
            .font(.ui(13))
            .padding(.horizontal, 8)
            .frame(height: 30)
        }
    }

    private func savedList(_ list: SavedList) -> some View {
        let on = session.currentList == list.name && session.pane == .results
        let count = Target.parse(list.targets, extractHostFromURL: list.options.extractHostFromURL).count
        return HoverButton(action: { session.runList(list.name) }, normal: on ? .white(0.08) : .clear, hover: .white(0.06), radius: 6) {
            HStack(spacing: 9) {
                Image(systemName: "bookmark").font(.system(size: 12, weight: .medium)).foregroundStyle(on ? Color.accentText : .t3).frame(width: 16)
                Text(list.name).lineLimit(1).truncationMode(.tail).foregroundStyle(on ? Color.white : .t1)
                Spacer(minLength: 0)
                Text(String(count)).font(.ui(11)).monospacedDigit().foregroundStyle(Color.white(0.35))
            }
            .font(.ui(13))
            .padding(.horizontal, 8)
            .frame(height: 30)
        }
        .contextMenu {
            Button("Rename…") {
                if let name = askName("Rename \(list.name) to", initial: list.name, button: "Rename") { session.renameList(list.name, to: name) }
            }
            Button("Delete", role: .destructive) { session.deleteList(list.name) }
        }
    }
}

private struct Header: View {
    @Bindable var session: Session

    var body: some View {
        HStack(spacing: 8) {
            if !session.showingSidebar {
                IconButton(symbol: "sidebar.left", color: .white(0.5), size: 14, width: 24, height: 22, help: "Show sidebar") {
                    session.showingSidebar = true
                }
                .padding(.leading, 70)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 2) {
                    Text(title).font(.ui(13, .bold)).foregroundStyle(Color.white(0.9))
                    if session.pane == .results { renameButton }
                }
                Text(subtitle).font(.ui(11)).foregroundStyle(Color.white(0.5)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if session.pane == .results { controls }
        }
        .padding(.leading, session.showingSidebar ? 20 : 0)
        .padding(.trailing, 12)
        .frame(height: 52)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white(0.08)).frame(height: 1) }
        .overlay(alignment: .bottomLeading) {
            if session.isRunning {
                GeometryReader { geo in
                    Rectangle().fill(Color.accent).frame(width: geo.size.width * session.progress, height: 2)
                        .animation(.linear(duration: 0.1), value: session.progress)
                }
                .frame(height: 2)
                .offset(y: 1)
            }
        }
    }

    private var title: String {
        switch session.pane {
        case .results: session.currentList ?? "Untitled lookup"
        case .watch: "Watch"
        case .history: "History"
        }
    }

    private var subtitle: String {
        switch session.pane {
        case .watch: return "Repeat the lookup on a timer and mark what changed"
        case .history: return "\(session.history.count) lookups"
        case .results:
            guard !session.targetsText.isEmpty else { return "Look up DNS records for many names at once" }
            let targets = Target.parse(session.targetsText, extractHostFromURL: session.options.extractHostFromURL).count
            let types = RecordType.lookupOrder.filter(session.options.types.contains).map(\.description) + (session.options.dmarc ? ["DMARC"] : [])
            let server = session.serverText.trimmingCharacters(in: .whitespaces)
            return "\(targets) targets · \(types.joined(separator: ", ")) · \(server.isEmpty ? "System resolver" : server)"
        }
    }

    private var renameButton: some View {
        IconButton(symbol: "pencil", color: session.popover == .rename ? .accentText : .white(0.45), size: 11, width: 20, height: 18,
                   help: session.currentList == nil ? "Name this lookup and save it as a list" : "Rename this lookup") {
            session.lookupName = session.currentList ?? ""
            session.popover = session.popover == .rename ? nil : .rename
        }
        .overlay(alignment: .topLeading) {
            if session.popover == .rename {
                Panel(radius: 10, padding: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(session.currentList == nil ? "Save Lookup As" : "Rename Lookup").font(.ui(12, .bold))
                        HStack(spacing: 8) {
                            TextField("Lookup name", text: $session.lookupName)
                                .textFieldStyle(.plain)
                                .font(.ui(12.5))
                                .fieldStyle(focused: true)
                                .onSubmit { session.nameLookup() }
                            SecondaryButton(title: "Save") { session.nameLookup() }
                                .disabled(session.lookupName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        Text("Saved as a list in the sidebar with the current Targets, Server, and options.")
                            .font(.ui(11)).foregroundStyle(Color.white(0.45)).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                .frame(width: 300)
                .offset(x: -8, y: 24)
            }
        }
    }

    private var filtered: Bool { session.outcomes.count < Outcome.allCases.count || session.onlyDiffers || session.cloudflareFilter != .any }

    private var controls: some View {
        HStack(spacing: 8) {
            HoverButton(action: session.openLookup, normal: .accent, hover: .accentHover, radius: 7) {
                HStack(spacing: 6) {
                    Image(systemName: "globe").font(.system(size: 12, weight: .semibold))
                    Text("Look Up").font(.ui(13, .medium))
                }
                .foregroundStyle(.white)
                .padding(.leading, 9)
                .padding(.trailing, 11)
                .frame(height: 28)
            }
            .help("Targets and options (⌘K)")
            HStack(spacing: 0) {
                if session.isRunning {
                    IconButton(symbol: "stop.fill", color: .bad, help: "Stop (⌘.)") { session.stop() }
                } else {
                    IconButton(symbol: "arrow.clockwise", help: "Look up the same Targets again (⌘R)") { session.run() }
                        .disabled(session.targetsText.isEmpty)
                        .opacity(session.targetsText.isEmpty ? 0.4 : 1)
                }
                IconButton(symbol: "timer", color: session.autoRefresh > 0 ? .ok : .white(0.75), on: session.autoRefresh > 0,
                           onBackground: .ok.opacity(0.14), help: "Auto refresh") { toggle(.autoRefresh) }
                    .overlay(alignment: .topLeading) {
                        if session.popover == .autoRefresh { autoRefreshMenu.offset(x: -60, y: 32) }
                    }
                IconButton(symbol: "square.and.arrow.up", help: "Export (⌘S)") { session.openExport() }
                    .disabled(session.rows.isEmpty)
                    .opacity(session.rows.isEmpty ? 0.4 : 1)
                IconButton(symbol: "line.3.horizontal.decrease", color: filtered ? .accentText : .white(0.75), on: filtered,
                           onBackground: .accent.opacity(0.18), help: "Choose which results and columns to show") { toggle(.filter) }
                    .overlay(alignment: .topTrailing) {
                        if session.popover == .filter { FilterPanel(session: session).offset(x: 40, y: 32) }
                    }
            }
            .padding(.horizontal, 2)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white(0.06)))
            searchField
            IconButton(symbol: "sidebar.right", color: session.showingInspector ? .white(0.9) : .white(0.6), size: 14, height: 28,
                       on: session.showingInspector, help: "Inspector (⌘I)") { session.showingInspector.toggle() }
        }
    }

    private func toggle(_ popover: Popover) {
        session.popover = session.popover == popover ? nil : popover
    }

    private var autoRefreshMenu: some View {
        Panel {
            VStack(alignment: .leading, spacing: 0) {
                Text("Auto Refresh").font(.ui(11, .semibold)).foregroundStyle(Color.white(0.4)).padding(.horizontal, 9).padding(.vertical, 5)
                ForEach(Session.intervals, id: \.seconds) { interval in
                    MenuItem(label: interval.menu, checked: session.autoRefresh == interval.seconds) {
                        session.autoRefresh = interval.seconds
                        session.popover = nil
                    }
                }
            }
        }
        .frame(width: 190)
        .fixedSize()
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.white(0.45))
            TextField("Search records", text: $session.search)
                .textFieldStyle(.plain)
                .font(.ui(13))
                .foregroundStyle(Color.white(0.9))
                .onExitCommand { if !session.closeOverlays() { session.search = "" } }
            if !session.search.isEmpty {
                Button { session.search = "" } label: {
                    Image(systemName: "xmark").font(.system(size: 7, weight: .heavy)).foregroundStyle(Color.window)
                        .frame(width: 14, height: 14).background(Circle().fill(Color.white(0.25)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(width: 200, height: 28)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white(0.06)))
    }
}

private struct FilterPanel: View {
    @Bindable var session: Session

    var body: some View {
        Panel(radius: 10, padding: 0) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Results").font(.ui(12, .bold)).padding(.bottom, 2)
                    ForEach(Outcome.allCases, id: \.self) { outcome in
                        Checkbox(label: outcome.rawValue, on: session.outcomes.contains(outcome), dot: outcome.tint) {
                            if session.outcomes.contains(outcome) { session.outcomes.remove(outcome) } else { session.outcomes.insert(outcome) }
                        }
                    }
                    Rectangle().fill(Color.white(0.1)).frame(height: 1).padding(.vertical, 4)
                    Checkbox(label: "Only rows where servers differ", on: session.onlyDiffers) { session.onlyDiffers.toggle() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Columns").font(.ui(12, .bold))
                        Spacer()
                        Button("Show All") { session.visibleColumns = Set(ResultsColumn.all.map(\.id)) }
                            .buttonStyle(.plain)
                            .font(.ui(12))
                            .foregroundStyle(Color.accentText)
                    }
                    .padding(.bottom, 2)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10, alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 6) {
                        ForEach(ResultsColumn.all) { column in
                            Checkbox(label: column.id == "index" ? "# (row)" : column.label, on: session.visibleColumns.contains(column.id), size: 12.5) {
                                if session.visibleColumns.contains(column.id) { session.visibleColumns.remove(column.id) } else { session.visibleColumns.insert(column.id) }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
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

@MainActor func focusSearch() {
    guard let window = NSApp.keyWindow, let root = window.contentView?.superview else { return }
    func find(_ view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable, field.placeholderString == "Search records" { return field }
        return view.subviews.lazy.compactMap(find).first
    }
    if let field = find(root) { window.makeFirstResponder(field) }
}
