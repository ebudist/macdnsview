import AppKit
import MacDNSViewCore
import SwiftUI

struct ResultsColumn: Identifiable {
    let id: String
    let label: String
    var width: CGFloat? = nil
    var minWidth: CGFloat = 0
    var fraction: CGFloat = 0
    var trailing = false

    static let all = [
        ResultsColumn(id: "index", label: "#", width: 54),
        ResultsColumn(id: "target", label: "Target", minWidth: 110, fraction: 1.1),
        ResultsColumn(id: "type", label: "Type", width: 54),
        ResultsColumn(id: "name", label: "Name", minWidth: 110, fraction: 1),
        ResultsColumn(id: "address", label: "Address", minWidth: 100, fraction: 0.9),
        ResultsColumn(id: "data", label: "Data", minWidth: 140, fraction: 2),
        ResultsColumn(id: "section", label: "Section", width: 70),
        ResultsColumn(id: "ttl", label: "TTL", width: 58, trailing: true),
        ResultsColumn(id: "server", label: "Server", width: 78),
        ResultsColumn(id: "time", label: "Time", width: 72, trailing: true),
        ResultsColumn(id: "validated", label: "DNSSEC", width: 70),
        ResultsColumn(id: "differs", label: "Differs", width: 58),
    ]

    static func widths(_ columns: [ResultsColumn], in total: CGFloat) -> [CGFloat] {
        let fixed = columns.compactMap(\.width).reduce(0, +)
        let fractions = columns.filter { $0.width == nil }.map(\.fraction).reduce(0, +)
        let free = max(0, total - fixed)
        return columns.map { $0.width ?? max($0.minWidth, fractions == 0 ? 0 : free * $0.fraction / fractions) }
    }
}

struct ResultsView: View {
    @Bindable var session: Session

    var body: some View {
        if session.rows.isEmpty, !session.isRunning {
            emptyState
        } else {
            VStack(spacing: 0) {
                filterBar.zIndex(1)
                Rectangle().fill(Color.white(0.06)).frame(height: 1)
                ResultsGrid(session: session)
                statusBar
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            BrandMark()
                .frame(width: 44, height: 44)
                .frame(width: 72, height: 72)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color(hex: 0x201E1D)))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white(0.1)))
                .shadow(color: .black.opacity(0.4), radius: 12, y: 8)
                .padding(.bottom, 8)
            Text("No lookups yet").font(.ui(17, .bold))
            Text("Paste domains, IP addresses, or URLs, or drop a text file here.")
                .font(.ui(13))
                .foregroundStyle(Color.white(0.5))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            HStack(spacing: 10) {
                PrimaryButton(height: 28, radius: 7, action: session.openLookup) { Text("Look Up…") }
                Text("⌘K").font(.ui(12)).foregroundStyle(Color.white(0.35))
            }
            .padding(.top, 10)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filterBar: some View {
        let counts = Dictionary(grouping: session.rows, by: \.outcome).mapValues(\.count)
        let all = session.outcomes.count == Outcome.allCases.count
        let differs = session.rows.filter { $0.differs == true }.count
        return HStack(spacing: 14) {
            SegmentedBar(segments: [Segment(id: "all", label: "All", count: String(session.rows.count), on: all) { session.outcomes = Set(Outcome.allCases) }] +
                Outcome.allCases.map { outcome in
                    Segment(id: outcome.rawValue, label: outcome.rawValue, count: String(counts[outcome] ?? 0),
                            on: session.outcomes == [outcome]) { session.outcomes = [outcome] }
                })
            Button { session.onlyDiffers.toggle() } label: {
                HStack(spacing: 8) {
                    Switch(on: session.onlyDiffers)
                    Text("Differs").foregroundStyle(Color.white(0.7))
                    if differs > 0 { Text(String(differs)).font(.ui(11)).foregroundStyle(Color.warn).monospacedDigit() }
                }
                .font(.ui(12))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Only rows where servers differ")
            .padding(.trailing, -8)
            hint(.differsHint, title: "Differs", text: Self.differsHint)
            HStack(spacing: 7) {
                Image(systemName: "cloud.fill").font(.system(size: 13)).foregroundStyle(Color.cloudflare)
                Text("Cloudflare").font(.ui(12)).foregroundStyle(Color.white(0.7))
                SegmentedBar(segments: CloudflareFilter.allCases.map { filter in
                    Segment(id: filter.rawValue, label: filter.rawValue, help: filter.help, on: session.cloudflareFilter == filter) { session.cloudflareFilter = filter }
                }, padding: 9)
            }
            .help("Cloudflare: matched against cloudflare.com/ips and *.ns.cloudflare.com")
            .padding(.trailing, -8)
            hint(.cloudflareHint, title: "Cloudflare", text: Self.cloudflareHint)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .frame(height: 44)
    }

    private static let differsHint = "A row differs when you look up against two or more servers and this server's answer for the Target and record type is not the answer most servers gave. Turn the switch on to show only those rows. With one server nothing can differ."
    private static let cloudflareHint = "Marks Targets served by Cloudflare: an A or AAAA answer inside Cloudflare's published IP ranges (cloudflare.com/ips), or an NS answer that is a cloudflare.com host. On shows only those Targets, Off hides them, Any shows everything. Only A, AAAA, and NS answers are checked, so a lookup of MX or TXT alone never finds Cloudflare."

    private func hint(_ popover: Popover, title: String, text: String) -> some View {
        IconButton(symbol: "questionmark.circle", color: session.popover == popover ? .accentText : .white(0.45), size: 12, width: 20, height: 20,
                   help: "What is \(title)?") {
            session.popover = session.popover == popover ? nil : popover
        }
        .overlay(alignment: .topLeading) {
            if session.popover == popover {
                Panel(radius: 10, padding: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title).font(.ui(12, .bold))
                        Text(text).font(.ui(12)).foregroundStyle(Color.white(0.75)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                .frame(width: 300)
                .offset(x: -10, y: 26)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if session.isRunning { Spinner() }
            ForEach(Array(statusParts.enumerated()), id: \.offset) { i, part in
                if i > 0 { Text("·").foregroundStyle(Color.white(0.25)) }
                Text(part.0).foregroundStyle(part.1)
            }
            Spacer(minLength: 0)
        }
        .font(.ui(11.5))
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(Color.statusBar)
        .overlay(alignment: .top) { Rectangle().fill(Color.white(0.08)).frame(height: 1) }
    }

    private var statusParts: [(String, Color)] {
        let rows = session.rows
        let counts = Dictionary(grouping: rows, by: \.outcome).mapValues(\.count)
        var parts: [(String, Color)] = [("\(rows.count) rows", .t2)]
        if let ok = counts[.ok] { parts.append(("\(ok) OK", .ok)) }
        if let noData = counts[.noData] { parts.append(("\(noData) NODATA", .warn)) }
        if let failed = counts[.failed] { parts.append(("\(failed) failed", .bad)) }
        if session.isFiltered { parts.append(("\(session.visibleRows.count) shown", .t2)) }
        let cloudflare = session.cloudflareTargets.count
        if cloudflare > 0 { parts.append(("\(cloudflare) target\(cloudflare == 1 ? "" : "s") on Cloudflare", .cloudflare)) }
        if !session.selection.isEmpty { parts.append(("\(session.selection.count) selected", .t2)) }
        if session.isRunning { parts.append(("looking up \(session.targetCount) targets", .accentText)) }
        if !session.isRunning, !session.changed.isEmpty || !session.removed.isEmpty {
            parts.append(("\(session.changed.count) changed, \(session.removed.count) gone since the last run", .accentText))
        }
        if session.wasStopped { parts.append(("stopped after \(Set(rows.map(\.target)).count) of \(session.targetCount) targets", .warn)) }
        if session.autoRefresh > 0, !session.isRunning, let next = session.nextRefresh {
            parts.append(("next refresh at \(next.formatted(date: .omitted, time: .standard))", .t2))
        }
        return parts
    }
}

extension CloudflareFilter {
    var help: String {
        switch self {
        case .any: "All targets"
        case .only: "Only targets with Cloudflare IPs or nameservers"
        case .exclude: "Hide targets on Cloudflare"
        }
    }
}

private struct ResultsGrid: View {
    @Bindable var session: Session

    var body: some View {
        let columns = ResultsColumn.all.filter { session.visibleColumns.contains($0.id) }
        let rows = session.visibleRows
        GeometryReader { geo in
            let widths = ResultsColumn.widths(columns, in: geo.size.width - 16)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        SwiftUI.Section {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { k, row in
                                rowView(row, odd: k % 2 == 1, columns: columns, widths: widths).id(row.id)
                            }
                            if !session.isRunning, !session.rows.isEmpty, session.visibleRows.isEmpty { noMatch }
                        } header: {
                            header(columns: columns, widths: widths)
                        }
                    }
                    .padding(.bottom, 12)
                }
                .onChange(of: session.selection) { _, selection in
                    if let id = selection.first { proxy.scrollTo(id) }
                }
            }
        }
    }

    private func header(columns: [ResultsColumn], widths: [CGFloat]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(columns.enumerated()), id: \.element.id) { i, column in
                HeaderCell(column: column, sort: session.sort) {
                    session.sort = session.sort?.column != column.id ? SortKey(column: column.id, ascending: true)
                        : session.sort!.ascending ? SortKey(column: column.id, ascending: false) : nil
                }
                .frame(width: widths[i])
            }
        }
        .frame(height: 28)
        .padding(.horizontal, 8)
        .background(Color.window)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white(0.08)).frame(height: 1) }
        .padding(.bottom, 4)
    }

    private func rowView(_ row: Row, odd: Bool, columns: [ResultsColumn], widths: [CGFloat]) -> some View {
        let selected = session.selection.contains(row.id)
        return HStack(spacing: 0) {
            ForEach(Array(columns.enumerated()), id: \.element.id) { i, column in
                cell(column, row, selected: selected)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 8)
                    .frame(width: widths[i], alignment: column.trailing ? .trailing : .leading)
            }
        }
        .font(.ui(12))
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accent.opacity(0.32) : odd ? .white(0.025) : .clear))
        .contentShape(Rectangle())
        .onTapGesture {
            if NSApp.currentEvent?.clickCount == 2 { showDetails(row) } else { session.selection = [row.id] }
        }
        .contextMenu {
            Button("Show Details") { showDetails(row) }
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(export([row], as: .tsv), forType: .string)
            }
        }
        .padding(.horizontal, 8)
    }

    private func showDetails(_ row: Row) {
        session.selection = [row.id]
        session.showingInspector = true
    }

    @ViewBuilder private func cell(_ column: ResultsColumn, _ row: Row, selected: Bool) -> some View {
        let dim = selected ? Color.white(0.8) : .t2
        let faint = selected ? Color.white(0.6) : .t3
        let outcome = row.outcome.cellColor
        switch column.id {
        case "index":
            HStack(spacing: 5) {
                if session.changed.contains(row.id) {
                    Circle().fill(Color.accent).frame(width: 6, height: 6).help("New or changed since the last run")
                }
                Text(String(row.index)).font(.mono(12)).foregroundStyle(faint)
                switch Cloudflare.match(row) {
                case .range(let cidr): cloud.help("Cloudflare IP range \(cidr)")
                case .nameserver: cloud.help("Cloudflare nameserver")
                case nil: EmptyView()
                }
            }
        case "target": Text(row.target).fontWeight(.medium).foregroundStyle(row.outcome == .ok ? Color.white(0.92) : outcome)
        case "type": Text(row.typeName).font(.mono(12)).foregroundStyle(row.outcome == .ok ? dim : outcome)
        case "name": Text(row.name).font(.mono(12)).foregroundStyle(row.outcome == .ok ? dim : outcome)
        case "address": Text(row.address).font(.mono(12)).foregroundStyle(row.outcome == .ok ? dim : outcome)
        case "data": Text(row.value).font(.mono(12)).foregroundStyle(outcome)
        case "section": Text(row.section?.rawValue ?? "").foregroundStyle(row.outcome == .ok ? dim : outcome)
        case "ttl": Text(row.ttl.map(String.init) ?? "").font(.mono(12)).foregroundStyle(dim)
        case "server": Text(row.server).font(.mono(12)).foregroundStyle(dim)
        case "time": Text(row.time.map { "\($0) ms" } ?? "").font(.mono(12)).foregroundStyle((row.time ?? 0) > 50 ? Color.warn : dim)
        case "validated":
            if row.validated == true {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.ok)
            } else {
                Text(row.validated == false && row.outcome == .ok ? "no" : "").foregroundStyle(faint)
            }
        default: Text(row.differs == true ? "yes" : "").fontWeight(.semibold).foregroundStyle(Color.warn)
        }
    }

    private var cloud: some View {
        Image(systemName: "cloud.fill").font(.system(size: 11)).foregroundStyle(Color.cloudflare)
    }

    private var noMatch: some View {
        VStack(spacing: 10) {
            Text(session.search.isEmpty ? "No rows with the chosen results" : "No rows match \u{201C}\(session.search)\u{201D}")
                .font(.ui(14, .semibold))
                .foregroundStyle(Color.white(0.8))
            HStack(spacing: 8) {
                if !session.search.isEmpty { SecondaryButton(title: "Clear Search", height: 24, size: 12) { session.search = "" } }
                SecondaryButton(title: "Show All Results", height: 24, size: 12) { session.showAllResults() }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }
}

private struct HeaderCell: View {
    let column: ResultsColumn
    let sort: SortKey?
    let action: () -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(column.label)
                if sort?.column == column.id {
                    Text(sort!.ascending ? "▲" : "▼").font(.system(size: 8)).foregroundStyle(Color.accentText)
                }
            }
            .font(.ui(11.5, .semibold))
            .foregroundStyle(hover.on ? Color.white(0.85) : .white(0.5))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: column.trailing ? .trailing : .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
    }
}

extension Row {
    var typeName: String { type.description }

    var value: String {
        if !address.isEmpty { return address }
        if error != nil || data.isEmpty { return error != nil ? data : name }
        return name == target ? data : "\(name)  \(data)"
    }
}
