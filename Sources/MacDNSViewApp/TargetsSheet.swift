import AppKit
import MacDNSViewCore
import SwiftUI
import UniformTypeIdentifiers

/// Targets, Server, record types, and Lookup options, in the place of DNSDataView's options dialog.
struct TargetsSheet: View {
    @Bindable var session: Session
    @Environment(\.dismiss) private var dismiss

    private static let presets = [("System", ""), ("1.1.1.1", "1.1.1.1"), ("8.8.8.8", "8.8.8.8"), ("9.9.9.9", "9.9.9.9"),
                                  ("Cloudflare DoH", "https://cloudflare-dns.com/dns-query"), ("Quad9 DoT", "tls://dns.quad9.net")]
    private static let types: [RecordType] = [.a, .aaaa, .cname, .mx, .ns, .soa, .srv, .txt, .caa, .https, .svcb, .ds, .dnskey]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Targets").font(.headline)
                Spacer()
                listsMenu
                Button("Load from File…") { session.importing = true }
            }
            TextEditor(text: $session.targetsText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 140)
                .overlay(alignment: .topLeading) {
                    if session.targetsText.isEmpty {
                        Text("Domains, IP addresses, or URLs, separated by lines, spaces, or commas")
                            .foregroundStyle(.tertiary).padding(6).allowsHitTesting(false)
                    }
                }
            Text(targetHint).font(.caption).foregroundStyle(.secondary)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Server").foregroundStyle(.secondary)
                    TextField("Leave empty to use local config, or separate servers by commas", text: $session.serverText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    HStack(spacing: 6) {
                        ForEach(Self.presets, id: \.0) { label, value in
                            Toggle(label, isOn: presetBinding(value))
                                .toggleStyle(.button)
                                .buttonBorderShape(.capsule)
                                .controlSize(.small)
                                .help(value.isEmpty ? "System configuration, including VPN scoped servers" : value)
                        }
                    }
                }
                if let problem = session.problem {
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        Text(problem).foregroundStyle(.red).font(.callout)
                    }
                }
                GridRow {
                    Text("Record types").foregroundStyle(.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                        ForEach(Self.types, id: \.self) { type in
                            Toggle(type.description, isOn: typeBinding(type)).typeChip()
                        }
                        Toggle("DMARC", isOn: $session.options.dmarc).typeChip()
                    }
                }
                GridRow {
                    Text("Follow-ups").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Reverse lookup (PTR) when a Target is an IP address", isOn: $session.options.reverseLookupAddresses)
                        Toggle("Look up PTR for every IP address in the answers", isOn: $session.options.ptrForEveryAddress)
                        Toggle("Look up A for every host name in PTR answers", isOn: $session.options.aForEveryPTRHost)
                        Toggle("Reduce URLs to their host", isOn: $session.options.extractHostFromURL)
                        Toggle("Show rows for failed lookups and empty answers", isOn: $session.options.showErrors)
                        Toggle("Hide the Additional section", isOn: $session.options.hideAdditional)
                    }
                    .toggleStyle(.checkbox)
                }
            }

            Divider()
            HStack {
                if let name = session.savingName {
                    TextField("List name", text: Binding { name } set: { session.savingName = $0 })
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .onSubmit(saveList)
                    Button("Save", action: saveList)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                } else {
                    Button("Save as List…") { session.savingName = session.currentList ?? "" }
                        .buttonStyle(.link)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Look Up") {
                    if let problem = session.serverProblem() {
                        session.problem = problem
                        return
                    }
                    session.problem = nil
                    session.run()
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: .command) // Return belongs to the Targets list
                .buttonStyle(.borderedProminent)
                .help("Look up (⌘↩)")
            }
        }
        .padding(20)
        .frame(width: 640)
        .onDisappear { session.savingName = nil }
        .fileImporter(isPresented: $session.importing, allowedContentTypes: [.plainText, .commaSeparatedText]) { result in
            if case .success(let url) = result {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do { try session.load(url) } catch { session.problem = error.localizedDescription }
            }
        }
    }

    private var listsMenu: some View {
        Menu(session.currentList ?? "Saved Lists") {
            if session.savedLists.isEmpty { Text("No saved lists") }
            ForEach(session.savedLists, id: \.name) { list in
                Button(list.name) { session.loadList(list) }
            }
        }
        .fixedSize()
        .help("Switch between saved Target lists")
    }

    private var targetHint: String {
        let targets = Target.parse(session.targetsText, extractHostFromURL: session.options.extractHostFromURL)
        guard !targets.isEmpty else { return "One per line works best. Lines starting with # are ignored." }
        let addresses = targets.filter { $0.kind != .name }.count
        return "\(targets.count) targets" + (addresses == 0 ? "" : " · \(addresses) IP address\(addresses == 1 ? "" : "es") looked up as PTR")
    }

    private func saveList() {
        guard let name = session.savingName?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return }
        session.saveList(as: name)
        session.savingName = nil
    }

    private func presetBinding(_ value: String) -> Binding<Bool> {
        let servers = { session.serverText.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init) }
        return Binding {
            value.isEmpty ? servers().isEmpty : servers().contains(value)
        } set: { on in
            let current = servers().filter { $0 != value }
            session.serverText = value.isEmpty ? "" : (on ? current + [value] : current).joined(separator: ", ")
            session.problem = nil
        }
    }

    private func typeBinding(_ type: RecordType) -> Binding<Bool> {
        Binding {
            session.options.types.contains(type)
        } set: { on in
            if on { session.options.types.insert(type) } else { session.options.types.remove(type) }
        }
    }
}

private extension Toggle {
    func typeChip() -> some View {
        toggleStyle(.button).controlSize(.small).font(.system(.caption, design: .monospaced).weight(.semibold))
    }
}
