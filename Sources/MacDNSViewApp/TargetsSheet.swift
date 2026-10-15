import MacDNSViewCore
import SwiftUI
import UniformTypeIdentifiers

/// Targets, Server, record types, and Lookup options, in the place of DNSDataView's options dialog.
struct TargetsSheet: View {
    @Bindable var session: Session
    @Environment(\.dismiss) private var dismiss

    private let typeGrid: [[RecordType?]] = [[.ns, .mx, .a, .aaaa], [.cname, .soa, .srv, .txt], [.caa, .https, .svcb, .ds], [.dnskey, nil]]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Targets").font(.headline)
                Spacer()
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

            LabeledContent("Server") {
                TextField("System configuration", text: $session.serverText)
                    .textFieldStyle(.roundedBorder)
            }
            if let problem = session.problem { Text(problem).foregroundStyle(.red).font(.callout) }

            GroupBox("Record types") {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    ForEach(typeGrid.indices, id: \.self) { row in
                        GridRow {
                            ForEach(typeGrid[row].indices, id: \.self) { column in
                                if let type = typeGrid[row][column] {
                                    Toggle(type.description, isOn: typeBinding(type))
                                } else {
                                    Toggle("DMARC", isOn: $session.options.dmarc)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            GroupBox("Follow-up lookups and display") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Reverse lookup (PTR) when a Target is an IP address", isOn: $session.options.reverseLookupAddresses)
                    Toggle("Look up PTR for every IP address in the answers", isOn: $session.options.ptrForEveryAddress)
                    Toggle("Look up A for every host name in PTR answers", isOn: $session.options.aForEveryPTRHost)
                    Toggle("Reduce URLs to their host", isOn: $session.options.extractHostFromURL)
                    Toggle("Show rows for failed lookups and empty answers", isOn: $session.options.showErrors)
                    Toggle("Hide the Additional section", isOn: $session.options.hideAdditional)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            HStack {
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
        .frame(width: 560)
        .fileImporter(isPresented: $session.importing, allowedContentTypes: [.plainText, .commaSeparatedText]) { result in
            if case .success(let url) = result {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do { try session.load(url) } catch { session.problem = error.localizedDescription }
            }
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
