import SwiftUI

struct HistoryTable: SiteDataTable {
    @Environment(AppModel.self) private var model
    @Binding var selection: Set<String>
    private let pages: [HistoryEntry]
    private let remove: (Set<String>) -> Void

    init(items: [HistoryEntry], selection: Binding<Set<String>>, remove: @escaping (Set<String>) -> Void) {
        pages = items.sorted { ($0.lastVisit ?? .distantPast) > ($1.lastVisit ?? .distantPast) }
        _selection = selection
        self.remove = remove
    }

    var body: some View {
        Table(pages, selection: $selection) {
            TableColumn("Title") { page in
                Text(page.title.isEmpty ? page.url : page.title)
                    .help(page.url)
            }
            TableColumn("Address") { page in
                Text(page.url)
                    .foregroundStyle(.secondary)
            }
            TableColumn("Last Visited") { page in
                Text(page.lastVisit?.formatted(date: .abbreviated, time: .shortened) ?? "–")
            }
            .width(min: 120, ideal: 150)
            TableColumn("Visits") { page in
                Text(page.visitCount, format: .number)
                    .monospacedDigit()
            }
            .width(min: 40, ideal: 50, max: 70)
            TableColumn("Browser") { Text(model.sourceName(for: $0)) }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if !ids.isEmpty {
                Button("Remove from History…", role: .destructive) { remove(ids) }
            }
        }
    }
}

struct CacheTable: SiteDataTable {
    @Environment(AppModel.self) private var model
    @Binding var selection: Set<String>
    private let entries: [CacheEntry]
    private let remove: (Set<String>) -> Void

    init(items: [CacheEntry], selection: Binding<Set<String>>, remove: @escaping (Set<String>) -> Void) {
        entries = items.sorted { $0.size > $1.size }
        _selection = selection
        self.remove = remove
    }

    var body: some View {
        Table(entries, selection: $selection) {
            TableColumn("Resource") { entry in
                Text(entry.name)
                    .help(entry.name)
            }
            TableColumn("Size") { entry in
                Text(entry.size.formatted(.byteCount(style: .file)))
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 80, max: 110)
            TableColumn("Last Used") { entry in
                Text(entry.lastUsed?.formatted(date: .abbreviated, time: .shortened) ?? "–")
            }
            .width(min: 120, ideal: 150)
            TableColumn("Browser") { Text(model.sourceName(for: $0)) }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if !ids.isEmpty {
                Button("Remove from Cache…", role: .destructive) { remove(ids) }
            }
        }
    }
}

struct CookieTable: SiteDataTable {
    @Environment(AppModel.self) private var model
    @Binding var selection: Set<String>
    @State private var copyError: String?
    private let cookies: [BrowserCookie]
    private let remove: (Set<String>) -> Void

    init(items: [BrowserCookie], selection: Binding<Set<String>>, remove: @escaping (Set<String>) -> Void) {
        cookies = items
        _selection = selection
        self.remove = remove
    }

    var body: some View {
        Table(cookies, selection: $selection) {
            TableColumn("Name") { Text($0.name) }
            TableColumn("Domain") { Text($0.domain) }
            TableColumn("Path") { Text($0.path) }
                .width(min: 40, ideal: 60)
            TableColumn("Expires") { cookie in
                Text(cookie.expires?.formatted(date: .abbreviated, time: .shortened) ?? "End of session")
            }
            TableColumn("Browser") { Text(model.sourceName(for: $0)) }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            // Clicking outside the rows copies every cookie listed.
            let chosen = ids.isEmpty ? cookies : cookies.filter { ids.contains($0.id) }
            if chosen.count == 1 {
                Button("Copy Value") { copy(chosen, as: .value) }
                Button("Copy as name=value") { copy(chosen, as: .pair) }
            }
            if !chosen.isEmpty {
                Button(ids.isEmpty ? "Copy All as Cookie Header" : "Copy as Cookie Header") { copy(chosen, as: .header) }
                Button(ids.isEmpty ? "Copy All as JSON" : "Copy as JSON") { copy(chosen, as: .json) }
            }
            if !ids.isEmpty {
                Divider()
                Button("Remove Cookies…", role: .destructive) { remove(ids) }
            }
        }
        .alert("Couldn't Copy",
               isPresented: Binding(get: { copyError != nil }, set: { if !$0 { copyError = nil } }),
               presenting: copyError) { _ in
        } message: { message in
            Text(message)
        }
    }

    private func copy(_ cookies: [BrowserCookie], as format: CookieCopyFormat) {
        Task {
            do {
                try await model.copy(cookies, as: format)
            } catch {
                copyError = error.localizedDescription
            }
        }
    }
}
