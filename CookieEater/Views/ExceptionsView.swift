import SwiftUI

struct ExceptionsView: View {
    @Environment(AppModel.self) private var model
    @State private var kind = DataKind.cookies
    @State private var newDomain = ""
    @State private var selection = Set<String>()

    private var noun: String { kind.title.lowercased() }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Add a site, e.g. example.com", text: $newDomain)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(Domain.normalize(newDomain).isEmpty)
            }
            .padding(12)
            Divider()
            List(model.settings[exceptionsFor: kind], id: \.self, selection: $selection) { domain in
                HStack {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                    Text(domain)
                    Spacer()
                    Text(keptDescription(for: domain))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .onDeleteCommand {
                model.removeExceptions(selection, for: kind)
            }
            .contextMenu(forSelectionType: String.self) { domains in
                if !domains.isEmpty {
                    Button("Remove") { model.removeExceptions(domains, for: kind) }
                }
            }
            .overlay {
                if model.settings[exceptionsFor: kind].isEmpty {
                    ContentUnavailableView("No \(kind.title) Exceptions", systemImage: "checkmark.shield",
                                           description: Text("Sites on this list, including their subdomains, keep their \(noun) when CookieEater cleans automatically or removes everything not excepted. Add sites here or from the \(kind.title) tab."))
                }
            }
            Divider()
            HStack {
                Text("An exception covers the site and all of its subdomains.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Remove") { model.removeExceptions(selection, for: kind) }
                    .disabled(selection.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .navigationTitle("Exceptions")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Data", selection: $kind) {
                    ForEach(DataKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .onChange(of: kind) {
            selection = []
        }
    }

    private func add() {
        let domain = Domain.normalize(newDomain)
        guard !domain.isEmpty else { return }
        model.addExceptions([domain], for: kind)
        newDomain = ""
    }

    /// How much of this kind of data the exception keeps.
    private func keptDescription(for domain: String) -> String {
        let kept = model.items(kind).filter { $0.host == domain || $0.host.hasSuffix("." + domain) }
        return kind == .cache ? kept.reduce(0) { $0 + $1.size }.formatted(.byteCount(style: .file)) : kind.count(kept.count)
    }
}
