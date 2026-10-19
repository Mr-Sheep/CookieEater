import SwiftUI

struct ExceptionsView: View {
    @Environment(AppModel.self) private var model
    @State private var newDomain = ""
    @State private var selection = Set<String>()

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
            List(model.settings.exceptions, id: \.self, selection: $selection) { domain in
                HStack {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                    Text(domain)
                    Spacer()
                    Text(cookieCountDescription(for: domain))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .onDeleteCommand {
                model.removeExceptions(selection)
            }
            .contextMenu(forSelectionType: String.self) { domains in
                if !domains.isEmpty {
                    Button("Remove") { model.removeExceptions(domains) }
                }
            }
            .overlay {
                if model.settings.exceptions.isEmpty {
                    ContentUnavailableView("No Exceptions", systemImage: "checkmark.shield",
                                           description: Text("Cookies from sites on this list, including their subdomains, are never removed automatically. Add sites here or from the cookie list."))
                }
            }
            Divider()
            HStack {
                Text("An exception covers the site and all of its subdomains.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Remove") { model.removeExceptions(selection) }
                    .disabled(selection.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .navigationTitle("Exceptions")
    }

    private func add() {
        let domain = Domain.normalize(newDomain)
        guard !domain.isEmpty else { return }
        model.addExceptions([domain])
        newDomain = ""
    }

    private func cookieCountDescription(for domain: String) -> String {
        let count = model.cookies.count { $0.host == domain || $0.host.hasSuffix("." + domain) }
        return count == 1 ? "1 cookie" : "\(count.formatted()) cookies"
    }
}
