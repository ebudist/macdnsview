import AppKit
import MacDNSViewCore
import SwiftUI
import UniformTypeIdentifiers

struct InspectorView: View {
    @Bindable var session: Session

    var body: some View {
        if let row = session.selectedRows.first, session.selection.count == 1 {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header(row)
                    Divider()
                    section("Record") {
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                            ForEach(fields(row), id: \.0) { label, value, color in
                                GridRow {
                                    Text(label).foregroundStyle(.secondary).gridColumnAlignment(.leading)
                                    Text(value).foregroundStyle(color.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary)).textSelection(.enabled)
                                }
                            }
                        }
                    }
                    Divider()
                    answersByServer(row)
                    Divider()
                    terminal(row)
                }
            }
        } else {
            ContentUnavailableView(session.selection.isEmpty ? "No selection" : "\(session.selection.count) rows selected", systemImage: "sidebar.right")
        }
    }

    private func header(_ row: Row) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Text(row.typeName)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.blue)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 9).fill(.blue.opacity(0.12)))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.blue.opacity(0.55)))
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.target).font(.title3.bold()).textSelection(.enabled)
                    HStack(spacing: 5) { ForEach(tags(row), id: \.0) { tag($0.0, $0.1) } }
                }
            }
            Text(row.value)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(row.outcome == .ok ? AnyShapeStyle(.primary) : AnyShapeStyle(row.outcome.color))
                .textSelection(.enabled)
        }
        .padding(20)
    }

    private func tag(_ label: String, _ color: Color) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.16)))
    }

    private func tags(_ row: Row) -> [(String, Color)] {
        var tags = [(row.outcome.rawValue.uppercased(), row.outcome.color)]
        if session.cloudflareTargets[row.target] != nil { tags.append(("CLOUDFLARE", .cloudflare)) }
        if row.differs == true { tags.append(("DIFFERS", .orange)) }
        if session.changed.contains(row.id) { tags.append(("CHANGED", .blue)) }
        if row.validated == true { tags.append(("DNSSEC", .secondary)) }
        return tags
    }

    private func fields(_ row: Row) -> [(String, String, Color?)] {
        let cloudflare: (String, Color?) = switch Cloudflare.match(row) {
        case .range(let cidr): ("In \(cidr)", .cloudflare)
        case .nameserver: ("Cloudflare nameserver", .cloudflare)
        case nil: session.cloudflareTargets[row.target].map { ("Target is on Cloudflare (via \($0))", .cloudflare) } ?? ("No", .secondary)
        }
        return [
            ("Name", row.name.isEmpty ? "" : row.name, nil),
            ("Section", row.section?.rawValue ?? "", nil),
            ("TTL", row.ttl.map { "\($0) (\(Duration.seconds($0).formatted(.units(allowed: [.days, .hours, .minutes, .seconds], width: .abbreviated))))" } ?? "", nil),
            ("Server", row.server, nil),
            ("Response time", row.time.map { "\($0) ms" } ?? "", (row.time ?? 0) > 50 ? .orange : nil),
            ("DNSSEC", row.validated == true ? "Validated (AD bit set)" : row.outcome == .ok ? "Not validated" : "", row.validated == true ? .green : .secondary),
            ("Cloudflare", cloudflare.0, cloudflare.1),
        ]
    }

    private func answersByServer(_ row: Row) -> some View {
        let siblings = session.rows.filter { $0.target == row.target && $0.type == row.type && ($0.section == .answer || $0.error != nil) }
        let servers = siblings.map(\.server).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let differs = siblings.contains { $0.differs == true }
        return section("Answers by server", note: servers.count < 2 ? ("One server", .secondary) : differs ? ("Servers disagree", .orange) : ("All servers agree", .green)) {
            VStack(spacing: 0) {
                ForEach(servers, id: \.self) { server in
                    let answers = siblings.filter { $0.server == server }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(server).fontWeight(.semibold).foregroundStyle(.secondary)
                            Spacer()
                            Text(answers.first?.time.map { "\($0) ms" } ?? "").foregroundStyle(.tertiary).monospacedDigit()
                        }
                        .font(.caption)
                        ForEach(answers) { answer in
                            Text(answer.value)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(answer.differs == true ? .orange : answer.outcome == .ok ? .primary : answer.outcome.color)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(server == row.server ? Color.primary.opacity(0.04) : .clear)
                    if server != servers.last { Divider() }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func terminal(_ row: Row) -> some View {
        let command = cliCommand(row)
        return section("Same lookup from Terminal") {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label("macdnsview CLI", systemImage: "terminal").foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        session.copiedCommand = true
                        Task { try? await Task.sleep(for: .seconds(1.4)); session.copiedCommand = false }
                    } label: {
                        Label(session.copiedCommand ? "Copied" : "Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                }
                .font(.caption)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                Divider()
                Text(command)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.background.secondary)
            }
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func cliCommand(_ row: Row) -> String {
        var parts = ["macdnsview"]
        if row.name.hasPrefix("_dmarc.") {
            parts += ["-t", "DMARC"]
        } else if RecordType.lookupOrder.contains(row.type) {
            parts += ["-t", row.typeName]
        }
        let servers = session.serverText.split(whereSeparator: { $0 == "," || $0.isWhitespace })
        if !servers.isEmpty { parts += ["-s", servers.joined(separator: ",")] }
        return (parts + [row.target]).joined(separator: " ")
    }

    private func section(_ title: String, note: (String, Color)? = nil, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.caption.bold())
                Spacer()
                if let note { Text(note.0).font(.caption).foregroundStyle(note.1) }
            }
            content()
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}

extension Row {
    var value: String {
        if !address.isEmpty { return address }
        if error != nil || data.isEmpty { return error != nil ? data : name }
        return name == target ? data : "\(name)  \(data)"
    }
}

struct WatchView: View {
    @Bindable var session: Session

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(headline).font(.headline)
                                Text(note).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let next = session.nextRefresh {
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    let left = max(0, Int(next.timeIntervalSince(context.date).rounded(.up)))
                                    Text(String(format: "%d:%02d", left / 60, left % 60)).font(.title2.weight(.semibold)).monospacedDigit()
                                }
                            }
                        }
                        Picker("Interval", selection: $session.autoRefresh) {
                            ForEach(Session.intervals, id: \.seconds) { Text($0.short).tag($0.seconds) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .disabled(session.targetsText.isEmpty)
                    }
                    .padding(8)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("Changes between runs").font(.caption.bold()).foregroundStyle(.secondary).padding(.bottom, 8)
                    if session.events.isEmpty {
                        Divider()
                        Text("Nothing yet. Each run after the first is compared with the one before.")
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 12)
                    }
                    ForEach(session.events) { event in
                        Divider()
                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                            Text(event.date.formatted(date: .omitted, time: .standard)).foregroundStyle(.secondary).monospacedDigit().frame(width: 84, alignment: .leading)
                            VStack(alignment: .leading, spacing: 5) {
                                Label {
                                    Text(title(event)).fontWeight(.semibold)
                                } icon: {
                                    Circle().fill(event.changed.isEmpty ? event.removed.isEmpty ? Color.secondary : .orange : .blue).frame(width: 7, height: 7)
                                }
                                .foregroundStyle(event.changed.isEmpty && event.removed.isEmpty ? .secondary : .primary)
                                ForEach(event.changed, id: \.self) { Text($0).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary) }
                                ForEach(event.removed, id: \.self) { Text($0).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).strikethrough() }
                            }
                        }
                        .padding(.vertical, 12)
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
        }
        .navigationTitle("Watch")
        .navigationSubtitle("Repeat the lookup on a timer and mark what changed")
    }

    private var name: String { session.currentList ?? "the current lookup" }

    private var headline: String {
        guard let interval = Session.intervals.first(where: { $0.seconds == session.autoRefresh }), interval.seconds > 0 else { return "Watch is off" }
        return "Refreshing \(name) \(interval.menu.lowercased())"
    }

    private var note: String {
        if session.autoRefresh > 0 { return "Rows that change between runs are marked with a blue dot in Results." }
        return session.targetsText.isEmpty ? "Run a lookup first, then pick an interval." : "Pick an interval to repeat \(name) and compare each run with the one before."
    }

    private func title(_ event: WatchEvent) -> String {
        let parts = [event.changed.isEmpty ? nil : "\(event.changed.count) changed", event.removed.isEmpty ? nil : "\(event.removed.count) gone"].compactMap { $0 }
        return parts.isEmpty ? "No changes" : parts.joined(separator: ", ")
    }
}

struct HistoryView: View {
    @Bindable var session: Session

    var body: some View {
        Table(session.history) {
            TableColumn("When") { Text($0.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary).monospacedDigit() }
                .width(min: 110, ideal: 140)
            TableColumn("List") { Text($0.list ?? "Untitled lookup").fontWeight(.semibold) }
            TableColumn("Targets") { Text(String($0.targetCount)).monospacedDigit() }
                .width(min: 50, ideal: 60)
            TableColumn("Types") { entry in
                Text((RecordType.lookupOrder.filter(entry.options.types.contains).map(\.description) + (entry.options.dmarc ? ["DMARC"] : [])).joined(separator: ", "))
                    .font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
            }
            TableColumn("Servers") { entry in
                Text(entry.server.isEmpty ? "System" : entry.server).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
            }
            TableColumn("Rows") { Text(String($0.rows)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing) }
                .width(min: 40, ideal: 50)
            TableColumn("Results") { entry in
                HStack(spacing: 10) {
                    Text("\(entry.ok) OK").foregroundStyle(.green)
                    if entry.noData > 0 { Text("\(entry.noData) NODATA").foregroundStyle(.orange) }
                    if entry.failed > 0 { Text("\(entry.failed) failed").foregroundStyle(.red) }
                }
                .monospacedDigit()
            }
        }
        .contextMenu(forSelectionType: HistoryEntry.ID.self) { ids in
            if let entry = session.history.first(where: { ids.contains($0.id) }) {
                Button("Look Up Again") { session.rerun(entry) }
            }
        } primaryAction: { ids in
            if let entry = session.history.first(where: { ids.contains($0.id) }) { session.rerun(entry) }
        }
        .overlay {
            if session.history.isEmpty { ContentUnavailableView("No lookups yet", systemImage: "clock.arrow.circlepath") }
        }
        .navigationTitle("History")
        .navigationSubtitle("\(session.history.count) lookups")
    }
}

struct ExportSheet: View {
    @Bindable var session: Session
    @Environment(\.dismiss) private var dismiss

    private static let formats: [(String, ExportFormat, String, UTType)] = [
        ("CSV", .csv, "csv", .commaSeparatedText), ("TSV", .tsv, "tsv", .tabSeparatedText), ("JSON", .json, "json", .json),
        ("Text", .table, "txt", .plainText), ("HTML", .html, "html", .html),
    ]

    private var rows: [Row] { session.exportSelected && !session.selectedRows.isEmpty ? session.selectedRows : session.visibleRows }
    private var format: (String, ExportFormat, String, UTType) { Self.formats.first { $0.1 == session.exportFormat } ?? Self.formats[0] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export rows").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 14) {
                GridRow {
                    Text("Format").foregroundStyle(.secondary)
                    Picker("Format", selection: $session.exportFormat) {
                        ForEach(Self.formats, id: \.1) { Text($0.0).tag($0.1) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    Text("Rows").foregroundStyle(.secondary)
                    Picker("Rows", selection: $session.exportSelected) {
                        Text("Selected rows (\(session.selectedRows.count))").tag(true).disabled(session.selectedRows.isEmpty)
                        Text("All shown rows (\(session.visibleRows.count))").tag(false)
                    }
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
                    .labelsHidden()
                }
                GridRow {
                    Text("File name").foregroundStyle(.secondary)
                    Text("macdnsview.\(format.2)").font(.system(.callout, design: .monospaced))
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Preview · first rows").font(.caption).foregroundStyle(.secondary)
                ScrollView([.horizontal, .vertical]) {
                    Text(export(Array(rows.prefix(6)), as: session.exportFormat))
                        .font(.system(.caption, design: .monospaced))
                        .fixedSize()
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(height: 170)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator))
            }
            HStack {
                Text("\(rows.count) row\(rows.count == 1 ? "" : "s") · all columns").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 580)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "macdnsview.\(format.2)"
        panel.allowedContentTypes = [format.3]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try export(rows, as: session.exportFormat).write(to: url, atomically: true, encoding: .utf8)
            dismiss()
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
