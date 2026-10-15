import AppKit
import MacDNSViewCore
import SwiftUI

struct InspectorView: View {
    @Bindable var session: Session

    var body: some View {
        if let row = session.selectedRows.first {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header(row)
                    divider
                    section("Record", spacing: 9) {
                        ForEach(fields(row), id: \.0) { label, value, color, weight in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(label).foregroundStyle(Color.white(0.5)).frame(width: 96, alignment: .leading)
                                Text(value).fontWeight(weight).foregroundStyle(color).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.ui(12.5))
                        }
                    }
                    divider
                    answersByServer(row)
                    divider
                    terminal(row)
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "sidebar.right").font(.system(size: 20, weight: .light)).foregroundStyle(Color.white(0.3))
                Text("No selection").font(.ui(13)).foregroundStyle(Color.white(0.4))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var divider: some View { Rectangle().fill(Color.white(0.08)).frame(height: 1) }

    private func header(_ row: Row) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Text(row.typeName)
                    .font(.mono(12, .bold))
                    .foregroundStyle(Color.accentText)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.accent.opacity(0.12)))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.accent.opacity(0.55)))
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.target).font(.ui(18, .bold)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    FlowTags(tags: tags(row))
                }
            }
            Text(row.value)
                .font(.mono(12.5))
                .foregroundStyle(row.outcome.cellColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 18)
    }

    private func tags(_ row: Row) -> [(String, Color, Color?)] {
        var tags: [(String, Color, Color?)] = [(row.outcome.rawValue.uppercased(), row.outcome.tint, nil)]
        if session.cloudflareTargets[row.target] != nil { tags.append(("CLOUDFLARE", .cloudflare, nil)) }
        if row.differs == true { tags.append(("DIFFERS", .warn, nil)) }
        if session.changed.contains(row.id) { tags.append(("CHANGED", .accentText, .accent.opacity(0.2))) }
        if row.validated == true { tags.append(("DNSSEC", .t2, .white(0.08))) }
        return tags
    }

    private func fields(_ row: Row) -> [(String, String, Color, Font.Weight)] {
        let ttl = row.ttl.map { "\($0) (\(Duration.seconds($0).formatted(.units(allowed: [.days, .hours, .minutes, .seconds], width: .abbreviated))))" } ?? ""
        let dnssec = row.validated == true ? "Validated (AD bit set)" : row.outcome == .ok ? "Not validated" : ""
        let cloudflare: (String, Color, Font.Weight) = switch Cloudflare.match(row) {
        case .range(let cidr): ("In \(cidr)", .cloudflare, .semibold)
        case .nameserver: ("Cloudflare nameserver", .cloudflare, .semibold)
        case nil: session.cloudflareTargets[row.target].map { ("Target is on Cloudflare (via \($0))", .cloudflare, .regular) } ?? ("No", .t2, .regular)
        }
        return [
            ("Name", row.name, .t1, .regular),
            ("Section", row.section?.rawValue ?? "", .t1, .regular),
            ("TTL", ttl, .t1, .regular),
            ("Server", row.server, .t1, .regular),
            ("Response time", row.time.map { "\($0) ms" } ?? "", (row.time ?? 0) > 50 ? .warn : .t1, .regular),
            ("DNSSEC", dnssec, row.validated == true ? .ok : .t2, row.validated == true ? .semibold : .regular),
            ("Cloudflare", cloudflare.0, cloudflare.1, cloudflare.2),
        ]
    }

    private func answersByServer(_ row: Row) -> some View {
        let siblings = session.rows.filter { $0.target == row.target && $0.type == row.type && ($0.section == .answer || $0.error != nil) }
        let servers = siblings.map(\.server).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let differs = siblings.contains { $0.differs == true }
        let note: (String, Color) = servers.count < 2 ? ("One server", .t3) : differs ? ("Servers disagree", .warn) : ("All servers agree", .ok)
        return section("Answers by server", note: note) {
            VStack(spacing: 0) {
                ForEach(servers, id: \.self) { server in
                    let answers = siblings.filter { $0.server == server }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(server).fontWeight(.semibold).foregroundStyle(Color.white(0.6))
                            Spacer()
                            Text(answers.first?.time.map { "\($0) ms" } ?? "").foregroundStyle(Color.white(0.4)).monospacedDigit()
                        }
                        .font(.ui(11.5))
                        ForEach(answers) { answer in
                            Text(answer.value)
                                .font(.mono(12))
                                .foregroundStyle(answer.differs == true ? Color.warn : answer.outcome == .ok ? .white(0.85) : answer.outcome.tint)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(server == row.server ? Color.white(0.04) : .clear)
                    .overlay(alignment: .top) { if server != servers.first { Rectangle().fill(Color.white(0.07)).frame(height: 1) } }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white(0.09)))
        }
    }

    private func terminal(_ row: Row) -> some View {
        let command = cliCommand(row)
        return section("Same lookup from Terminal", bottom: 20) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    Image(systemName: "terminal").font(.system(size: 11)).foregroundStyle(Color.white(0.5))
                    Text("macdnsview CLI").foregroundStyle(Color.white(0.55))
                    Spacer()
                    HoverButton(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        session.copiedCommand = true
                        Task { try? await Task.sleep(for: .seconds(1.4)); session.copiedCommand = false }
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: "doc.on.doc").font(.system(size: 10))
                            Text(session.copiedCommand ? "Copied" : "Copy")
                        }
                        .foregroundStyle(Color.white(0.7))
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                    }
                }
                .font(.ui(11.5))
                .padding(.leading, 11)
                .padding(.trailing, 6)
                .frame(height: 30)
                .overlay(alignment: .bottom) { Rectangle().fill(Color.white(0.07)).frame(height: 1) }
                Text(command)
                    .font(.mono(12))
                    .lineSpacing(3)
                    .foregroundStyle(Color.t1)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .background(Color.code)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white(0.09)))
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

    private func section(_ title: String, note: (String, Color)? = nil, spacing: CGFloat = 10, bottom: CGFloat = 16,
                         @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.ui(12, .bold))
                Spacer()
                if let note { Text(note.0).font(.ui(11.5)).foregroundStyle(note.1) }
            }
            .padding(.bottom, spacing == 9 ? 2 : 0)
            content()
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, bottom)
    }
}

private struct FlowTags: View {
    let tags: [(String, Color, Color?)]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) { content }
            VStack(alignment: .leading, spacing: 5) { content }
        }
    }

    @ViewBuilder private var content: some View {
        ForEach(tags, id: \.0) { Tag(label: $0.0, color: $0.1, background: $0.2) }
    }
}

struct WatchView: View {
    @Bindable var session: Session

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(headline).font(.ui(15, .bold))
                            Text(note).font(.ui(12.5)).foregroundStyle(Color.white(0.5))
                        }
                        Spacer()
                        if let next = session.nextRefresh, session.autoRefresh > 0 {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                let left = max(0, Int(next.timeIntervalSince(context.date).rounded(.up)))
                                Text(String(format: "%d:%02d", left / 60, left % 60)).font(.ui(22, .semibold)).monospacedDigit().foregroundStyle(Color.white(0.9))
                            }
                        }
                    }
                    SegmentedBar(segments: Session.intervals.map { interval in
                        Segment(id: String(interval.seconds), label: interval.short, on: session.autoRefresh == interval.seconds) {
                            session.autoRefresh = interval.seconds
                        }
                    }, height: 26, padding: 12)
                    .disabled(session.targetsText.isEmpty)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white(0.08)))
                VStack(alignment: .leading, spacing: 0) {
                    Text("Changes between runs").font(.ui(12, .bold)).foregroundStyle(Color.white(0.5)).padding(.bottom, 8)
                    if session.events.isEmpty {
                        Text("Nothing yet. Each run after the first is compared with the one before.")
                            .font(.ui(13))
                            .foregroundStyle(Color.t3)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(alignment: .top) { Rectangle().fill(Color.white(0.07)).frame(height: 1) }
                    }
                    ForEach(session.events) { event in
                        let quiet = event.changed.isEmpty && event.removed.isEmpty
                        self.event(time: event.date.formatted(date: .omitted, time: .standard), title: title(event), lines: event.changed, removed: event.removed,
                                   dot: quiet ? .white(0.25) : event.changed.isEmpty ? .warn : .accent, muted: quiet)
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
        }
    }

    private func event(time: String, title: String, lines: [String], removed: [String], dot: Color, muted: Bool) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(time).font(.ui(12)).monospacedDigit().foregroundStyle(Color.white(0.45)).frame(width: 84, alignment: .leading).padding(.top, 1)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Circle().fill(dot).frame(width: 7, height: 7)
                    Text(title).font(.ui(13, .semibold)).foregroundStyle(muted ? Color.t2 : .t1)
                }
                ForEach(lines, id: \.self) { Text($0).font(.mono(11.5)).foregroundStyle(Color.white(0.7)) }
                ForEach(removed, id: \.self) { Text($0).font(.mono(11.5)).foregroundStyle(Color.white(0.7)).strikethrough() }
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Color.white(0.07)).frame(height: 1) }
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

    private static let columns: [(String, CGFloat?, CGFloat)] = [("When", 130, 0), ("List", nil, 1.2), ("Targets", 70, 0), ("Types", nil, 1),
                                                                  ("Servers", nil, 1.2), ("Rows", 60, 0), ("Results", nil, 1.3)]

    var body: some View {
        GeometryReader { geo in
            let widths = widths(geo.size.width - 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        ForEach(Array(Self.columns.enumerated()), id: \.offset) { i, column in
                            Text(column.0).padding(.horizontal, 10).frame(width: widths[i], alignment: column.0 == "Rows" ? .trailing : .leading)
                        }
                    }
                    .font(.ui(11.5, .semibold))
                    .foregroundStyle(Color.white(0.5))
                    .frame(height: 30)
                    .overlay(alignment: .bottom) { Rectangle().fill(Color.white(0.08)).frame(height: 1) }
                    ForEach(session.history) { entry in HistoryRow(entry: entry, widths: widths) { session.rerun(entry) } }
                    if session.history.isEmpty {
                        Text("No lookups yet").font(.ui(13)).foregroundStyle(Color.white(0.4)).frame(maxWidth: .infinity).padding(.vertical, 80)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
        }
    }

    private func widths(_ total: CGFloat) -> [CGFloat] {
        let fixed = Self.columns.compactMap(\.1).reduce(0, +)
        let fractions = Self.columns.map(\.2).reduce(0, +)
        return Self.columns.map { $0.1 ?? max(0, total - fixed) * $0.2 / fractions }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let widths: [CGFloat]
    let action: () -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
        HStack(spacing: 0) {
            cell(0) { Text(when).foregroundStyle(Color.white(0.55)).monospacedDigit() }
            cell(1) { Text(entry.list ?? "Untitled lookup").fontWeight(.semibold) }
            cell(2) { Text(String(entry.targetCount)).monospacedDigit() }
            cell(3) { Text(types).font(.mono(11.5)).foregroundStyle(Color.white(0.7)) }
            cell(4) { Text(entry.server.isEmpty ? "System" : entry.server).font(.mono(11.5)).foregroundStyle(Color.white(0.7)) }
            cell(5, trailing: true) { Text(String(entry.rows)).monospacedDigit() }
            cell(6) {
                HStack(spacing: 10) {
                    Text("\(entry.ok) OK").foregroundStyle(Color.ok)
                    if entry.noData > 0 { Text("\(entry.noData) NODATA").foregroundStyle(Color.warn) }
                    if entry.failed > 0 { Text("\(entry.failed) failed").foregroundStyle(Color.bad) }
                }
                .font(.ui(12))
                .monospacedDigit()
            }
        }
        .font(.ui(12.5))
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 6).fill(hover.on ? Color.white(0.05) : .clear))
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
        .onTapGesture(perform: action)
        .help("Look up again")
    }

    private var when: String {
        let time = entry.date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDateInToday(entry.date) { return "Today \(time)" }
        if calendar.isDateInYesterday(entry.date) { return "Yesterday \(time)" }
        if entry.date > Date().addingTimeInterval(-6 * 86400) { return "\(entry.date.formatted(.dateTime.weekday())) \(time)" }
        return entry.date.formatted(date: .abbreviated, time: .shortened)
    }

    private var types: String {
        (RecordType.lookupOrder.filter(entry.options.types.contains).map(\.description) + (entry.options.dmarc ? ["DMARC"] : [])).joined(separator: ", ")
    }

    private func cell(_ i: Int, trailing: Bool = false, @ViewBuilder content: () -> some View) -> some View {
        content().lineLimit(1).truncationMode(.tail).padding(.horizontal, 10).frame(width: widths[i], alignment: trailing ? .trailing : .leading)
    }
}
