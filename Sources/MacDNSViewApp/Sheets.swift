import AppKit
import MacDNSViewCore
import SwiftUI
import UniformTypeIdentifiers

struct SheetPanel<Content: View, Footer: View>: View {
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) { content() }
                .padding(.horizontal, 22)
                .padding(.top, 20)
            HStack(spacing: 8) { footer() }
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .overlay(alignment: .top) { Rectangle().fill(Color.white(0.08)).frame(height: 1) }
                .padding(.top, 20)
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.sheet))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white(0.14)))
        .shadow(color: .black.opacity(0.6), radius: 30, y: 24)
    }
}

func formLabel(_ text: String) -> some View {
    Text(text).font(.ui(13)).foregroundStyle(Color.white(0.7)).frame(width: 96, alignment: .leading)
}

struct TargetsSheet: View {
    @Bindable var session: Session

    private static let presets = [("System", ""), ("1.1.1.1", "1.1.1.1"), ("8.8.8.8", "8.8.8.8"), ("9.9.9.9", "9.9.9.9"),
                                  ("Cloudflare DoH", "https://cloudflare-dns.com/dns-query"), ("Quad9 DoT", "tls://dns.quad9.net")]
    private static let types: [RecordType] = [.a, .aaaa, .cname, .mx, .ns, .soa, .srv, .txt, .caa, .https, .svcb, .ds, .dnskey]
    private static let followUps: [(String, WritableKeyPath<LookupOptions, Bool>)] = [
        ("Reverse lookup (PTR) when a Target is an IP address", \.reverseLookupAddresses),
        ("Look up PTR for every IP address in the answers", \.ptrForEveryAddress),
        ("Look up A for every host name in PTR answers", \.aForEveryPTRHost),
        ("Reduce URLs to their host", \.extractHostFromURL),
        ("Show rows for failed lookups and empty answers", \.showErrors),
        ("Hide the Additional section", \.hideAdditional),
    ]

    var body: some View {
        SheetPanel {
            HStack(spacing: 8) {
                Text("Targets").font(.ui(13, .bold)).frame(maxWidth: .infinity, alignment: .leading)
                SmallButton(title: "Clear") { session.targetsText = ""; session.problem = nil }
                    .help("Empty the Targets field")
                    .disabled(session.targetsText.isEmpty)
                    .opacity(session.targetsText.isEmpty ? 0.5 : 1)
                SmallButton(title: "New Session") { session.newSession() }
                    .help("Start an untitled lookup with empty Targets, the system resolver, and default options")
                listsButton
                SmallButton(title: "Load from File…") { session.importing = true }
            }
            .zIndex(1)
            VStack(alignment: .leading, spacing: 6) {
                TextEditor(text: $session.targetsText)
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
                        if session.targetsText.isEmpty {
                            Text("Domains, IP addresses, or URLs, separated by lines, spaces, or commas")
                                .font(.mono(12.5)).foregroundStyle(Color.white(0.3)).padding(.horizontal, 11).padding(.vertical, 9).allowsHitTesting(false)
                        }
                    }
                Text(targetHint).font(.ui(11.5)).foregroundStyle(Color.white(0.45))
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    formLabel("Server")
                    TextField("Leave empty to use local config, or separate servers by commas", text: $session.serverText)
                        .textFieldStyle(.plain)
                        .font(.mono(12))
                        .foregroundStyle(Color.white(0.9))
                        .fieldStyle()
                        .onChange(of: session.serverText) { session.problem = nil }
                }
                HStack(spacing: 6) {
                    ForEach(Self.presets, id: \.0) { label, value in presetChip(label, value) }
                }
                .padding(.leading, 108)
                if let problem = session.problem {
                    Text(problem).font(.ui(12)).foregroundStyle(Color.problem).lineSpacing(2).padding(.leading, 108)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    formLabel("Record types").padding(.top, 3)
                    linkButton("Select All") {
                        session.options.types = Set(Self.types)
                        session.options.dmarc = true
                        session.problem = nil
                    }
                    linkButton("Unselect All") {
                        session.options.types = []
                        session.options.dmarc = false
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                    ForEach(Self.types, id: \.self) { type in
                        TypeChip(label: type.description, on: session.options.types.contains(type)) {
                            if session.options.types.contains(type) { session.options.types.remove(type) } else { session.options.types.insert(type) }
                            session.problem = nil
                        }
                    }
                    TypeChip(label: "DMARC", on: session.options.dmarc) { session.options.dmarc.toggle(); session.problem = nil }
                }
            }
            HStack(alignment: .top, spacing: 12) {
                formLabel("Follow-ups")
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Self.followUps, id: \.0) { label, path in
                        Checkbox(label: label, on: session.options[keyPath: path], size: 12.5) { session.options[keyPath: path].toggle() }
                    }
                }
            }
        } footer: {
            if let name = session.savingName {
                TextField("List name", text: Binding { name } set: { session.savingName = $0 })
                    .textFieldStyle(.plain)
                    .font(.ui(12.5))
                    .fieldStyle(focused: true)
                    .frame(width: 180)
                    .onSubmit(saveList)
                SecondaryButton(title: "Save", action: saveList)
            } else {
                HoverButton(action: { session.savingName = session.currentList ?? "" }, hover: .accent.opacity(0.12), radius: 6) {
                    Text("Save as List…").font(.ui(13)).foregroundStyle(Color.accentText).padding(.horizontal, 12).frame(height: 26)
                }
            }
            Spacer()
            SecondaryButton(title: "Cancel") { session.popover = nil; session.closeOverlays() }
            PrimaryButton(action: submit) {
                HStack(spacing: 8) {
                    Text("Look Up")
                    Text("⌘↩").font(.ui(11)).opacity(0.7)
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .help("Look up (⌘↩)")
        }
    }

    private func linkButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.ui(11.5)).foregroundStyle(Color.accentText) }
            .buttonStyle(.plain)
    }

    private var listsButton: some View {
        HoverButton(action: { session.popover = session.popover == .lists ? nil : .lists }, normal: .white(0.1), hover: .white(0.14), radius: 6) {
            HStack(spacing: 6) {
                Text(session.currentList ?? "Saved Lists")
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Color.white(0.6))
            }
            .font(.ui(12))
            .foregroundStyle(Color.t1)
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .frame(height: 24)
        }
        .overlay(alignment: .topTrailing) {
            if session.popover == .lists {
                Panel(background: .menu) {
                    VStack(alignment: .leading, spacing: 0) {
                        if session.savedLists.isEmpty {
                            Text("No saved lists").font(.ui(13)).foregroundStyle(Color.t3).padding(.horizontal, 9).frame(height: 24)
                        }
                        ForEach(session.savedLists, id: \.name) { list in
                            MenuItem(label: list.name) {
                                session.loadList(list)
                                session.popover = nil
                                session.problem = nil
                            }
                        }
                    }
                }
                .frame(width: 200)
                .offset(y: 28)
            }
        }
    }

    private func presetChip(_ label: String, _ value: String) -> some View {
        let servers = session.serverText.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
        let on = value.isEmpty ? servers.isEmpty : servers.contains(value)
        return Button {
            session.serverText = value.isEmpty ? "" : (on ? servers.filter { $0 != value } : servers + [value]).joined(separator: ", ")
            session.problem = nil
        } label: {
            Text(label)
                .font(.ui(11.5))
                .foregroundStyle(on ? Color.accentText : .t2)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(Capsule().fill(on ? Color.accent.opacity(0.18) : .clear))
                .overlay(Capsule().strokeBorder(on ? Color.accent.opacity(0.6) : .white(0.14)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(value.isEmpty ? "System configuration, including VPN scoped servers" : value)
    }

    private var targetHint: String {
        let targets = Target.parse(session.targetsText, extractHostFromURL: session.options.extractHostFromURL)
        guard !targets.isEmpty else { return "One per line works best. Lines starting with # are ignored." }
        let addresses = targets.filter { $0.kind != .name }.count
        return "\(targets.count) targets" + (addresses == 0 ? "" : " · \(addresses) IP address\(addresses == 1 ? "" : "es") looked up as PTR")
    }

    private func submit() {
        if Target.parse(session.targetsText, extractHostFromURL: session.options.extractHostFromURL).isEmpty {
            session.problem = "Add at least one Target."
        } else if session.options.types.isEmpty, !session.options.dmarc {
            session.problem = "Choose at least one record type."
        } else if let problem = session.serverProblem() {
            session.problem = problem
        } else {
            session.problem = nil
            session.savingName = nil
            session.popover = nil
            session.showingSheet = false
            session.run()
        }
    }

    private func saveList() {
        guard let name = session.savingName?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return }
        session.saveList(as: name)
        session.savingName = nil
        session.flash("Saved \u{201C}\(name)\u{201D}")
    }
}

struct SmallButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        HoverButton(action: action, normal: .white(0.1), hover: .white(0.14), radius: 6) {
            Text(title).font(.ui(12)).foregroundStyle(Color.t1).padding(.horizontal, 10).frame(height: 24)
        }
    }
}

private struct TypeChip: View {
    let label: String
    let on: Bool
    let action: () -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.mono(11.5, .semibold))
                .foregroundStyle(on ? Color.accentText : .t2)
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.accent.opacity(0.2) : .white(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(hover.on ? (on ? Color.accent : .white(0.3)) : on ? Color.accent.opacity(0.65) : .white(0.1)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
    }
}

struct ExportSheet: View {
    @Bindable var session: Session

    private static let formats: [(String, ExportFormat, String, UTType)] = [
        ("CSV", .csv, "csv", .commaSeparatedText), ("TSV", .tsv, "tsv", .tabSeparatedText), ("JSON", .json, "json", .json),
        ("Text", .table, "txt", .plainText), ("HTML", .html, "html", .html),
    ]

    private var rows: [Row] {
        (session.exportSource?.rows ?? (session.exportSelected && !session.selectedRows.isEmpty ? session.selectedRows : session.visibleRows))
            .map { $0.with(data: $0.value) }
    }
    private var columns: [Int] { ResultsColumn.all.indices.filter { session.visibleColumns.contains(ResultsColumn.all[$0].id) } }
    private var format: (String, ExportFormat, String, UTType) { Self.formats.first { $0.1 == session.exportFormat } ?? Self.formats[0] }

    var body: some View {
        SheetPanel {
            Text("Export rows").font(.ui(13, .bold))
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    formLabel("Format")
                    SegmentedBar(segments: Self.formats.map { name, format, _, _ in
                        Segment(id: name, label: name, on: session.exportFormat == format) { session.exportFormat = format }
                    }, height: 26, padding: 12, background: .white(0.07))
                }
                HStack(spacing: 12) {
                    formLabel("Rows")
                    if let source = session.exportSource {
                        Text("All rows from \(source.title) in History (\(source.rows.count))").font(.ui(12.5)).foregroundStyle(Color.white(0.85))
                    } else {
                        HStack(spacing: 18) {
                            radio("Selected row\(session.selectedRows.isEmpty ? "" : " (\(session.selectedRows.count))")", on: session.exportSelected && !session.selectedRows.isEmpty,
                                  disabled: session.selectedRows.isEmpty) { session.exportSelected = true }
                            radio("All shown rows (\(session.visibleRows.count))", on: !session.exportSelected || session.selectedRows.isEmpty, disabled: false) {
                                session.exportSelected = false
                            }
                        }
                    }
                }
                HStack(spacing: 12) {
                    formLabel("File name")
                    Text("macdnsview.\(format.2)").font(.mono(12)).foregroundStyle(Color.white(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading).fieldStyle()
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Preview · first rows").font(.ui(11.5)).foregroundStyle(Color.white(0.45))
                ScrollView([.horizontal, .vertical]) {
                    Text(export(Array(rows.prefix(6)), as: session.exportFormat, columns: columns))
                        .font(.mono(11.5))
                        .lineSpacing(4)
                        .foregroundStyle(Color.white(0.78))
                        .fixedSize()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(height: 170)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.code))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white(0.1)))
            }
        } footer: {
            Text("\(rows.count) row\(rows.count == 1 ? "" : "s") · visible columns").font(.ui(12)).foregroundStyle(Color.white(0.45))
            Spacer()
            SecondaryButton(title: "Cancel") { session.closeOverlays() }
            PrimaryButton(action: save) { Text("Export…") }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func radio(_ label: String, on: Bool, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Circle()
                    .fill(on ? Color.white : .clear)
                    .overlay(Circle().strokeBorder(on ? Color.accent : .white(0.3), lineWidth: on ? 4 : 1))
                    .frame(width: 14, height: 14)
                Text(label).font(.ui(12.5)).foregroundStyle(Color.white(0.85))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "macdnsview.\(format.2)"
        panel.allowedContentTypes = [format.3]
        guard let window = NSApp.keyWindow else { return }
        let (rows, format, columns) = (rows, session.exportFormat, columns)
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try export(rows, as: format, columns: columns).write(to: url, atomically: true, encoding: .utf8)
                session.closeOverlays()
                session.flash("Exported \(rows.count) rows as \(url.lastPathComponent)")
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }
}
