import SwiftUI

/// One browser, or all of them, with a tab for each kind of data.
struct BrowserDataView: View {
    @Environment(AppModel.self) private var model
    let scope: BrowserScope
    @Binding var kind: DataKind

    @State private var profileID: String?

    private var browser: InstalledBrowser? {
        if case .browser(let id) = scope { model.browser(withID: id) } else { nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(model.browsers(in: scope).filter { !model.blockedKinds(browserID: $0.id).isEmpty }) { browser in
                FolderAccessBanner(browser: browser)
                Divider()
            }
            if let browser {
                BrowserHeader(browser: browser, profileID: $profileID)
                Divider()
            }
            switch kind {
            case .history:
                SiteDataView<HistoryTable>(kind: .history, scope: scope, profileID: profileID, items: model.history)
            case .cache:
                SiteDataView<CacheTable>(kind: .cache, scope: scope, profileID: profileID, items: model.cache)
            case .cookies:
                SiteDataView<CookieTable>(kind: .cookies, scope: scope, profileID: profileID, items: model.cookies)
            }
        }
        .navigationTitle(browser?.name ?? "All Browsers")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Data", selection: $kind) {
                    ForEach(DataKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }
}

/// The cookies, history pages or cache entries of one site, combined across the browsers and profiles in view.
struct SiteGroup: Identifiable {
    /// Empty for cache files that aren't tied to a site.
    let site: String
    let isException: Bool
    var count = 0
    var size: Int64 = 0
    var browserIDs: Set<String> = []
    var profileIDs: Set<String> = []

    var id: String { site }

    static func groups(from items: [some SiteData], exceptions: ExceptionList) -> [SiteGroup] {
        var groups: [String: SiteGroup] = [:]
        for item in items {
            groups[item.site, default: SiteGroup(site: item.site, isException: exceptions.covers(item.site))].add(item)
        }
        return Array(groups.values)
    }

    private mutating func add(_ item: some SiteData) {
        count += 1
        size += item.size
        browserIDs.insert(item.browserID)
        profileIDs.insert(item.profileID)
    }
}

/// Lists the selected sites' items, below the list of sites.
protocol SiteDataTable: View {
    associatedtype Item: SiteData
    init(items: [Item], selection: Binding<Set<String>>, remove: @escaping (Set<String>) -> Void)
}

private enum SiteFilter: String, CaseIterable, Identifiable {
    case all = "All Sites"
    case removable = "Not Excepted"
    case exceptions = "Exceptions"

    var id: Self { self }
}

/// A removal waiting for confirmation.
private enum PendingAction: Identifiable {
    case removeSites(Set<String>)
    case removeItems(Set<String>)
    case removeNotExcepted

    var id: String {
        switch self {
        case .removeSites(let sites): "sites-\(sites.sorted())"
        case .removeItems(let ids): "items-\(ids.sorted())"
        case .removeNotExcepted: "not-excepted"
        }
    }
}

/// The sites holding one kind of data, the items of the selected sites, and what can be done with them.
struct SiteDataView<Details: SiteDataTable>: View {
    @Environment(AppModel.self) private var model
    let kind: DataKind
    let scope: BrowserScope
    let profileID: String?
    let items: [Details.Item]

    @State private var searchText = ""
    @State private var filter = SiteFilter.all
    @State private var selectedSites = Set<String>()
    @State private var selectedItems = Set<String>()
    @State private var sortOrder = [KeyPathComparator(\SiteGroup.site)]
    @State private var pendingAction: PendingAction?
    @State private var showsProblems = false

    private var browser: InstalledBrowser? {
        if case .browser(let id) = scope { model.browser(withID: id) } else { nil }
    }

    private var noun: String { kind.title.lowercased() }

    var body: some View {
        let scoped = scopedItems
        let groups = visibleGroups(from: scoped)
        VStack(spacing: 0) {
            // Without a flexible width, the split view starts at the tables' ideal width.
            VSplitView {
                sitesTable(groups)
                    .frame(maxWidth: .infinity, minHeight: 180, idealHeight: 340, maxHeight: .infinity)
                detailPane(scoped.filter { selectedSites.contains($0.site) })
                    .frame(maxWidth: .infinity, minHeight: 120, idealHeight: 200, maxHeight: .infinity)
            }
            Divider()
            actionBar(siteCount: groups.count, items: scoped)
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Filter Sites")
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Show", selection: $filter) {
                        ForEach(SiteFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Show", systemImage: filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
                .help("Show all sites, only those not excepted, or only exceptions")
            }
            ToolbarItem {
                Button("Reload", systemImage: "arrow.clockwise") {
                    Task { await model.reload() }
                }
                .disabled(model.isLoading)
            }
        }
        .onChange(of: selectedSites) {
            selectedItems = []
        }
        .onChange(of: profileID) {
            selectedSites = []
        }
        .confirmationDialog(pendingAction.map(dialogTitle) ?? "",
                            isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }),
                            presenting: pendingAction) { action in
            Button("Remove", role: .destructive) { perform(action) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(dialogMessage)
        }
    }

    private var scopedItems: [Details.Item] {
        items.filter { item in
            switch scope {
            case .allBrowsers: true
            case .browser(let id): item.browserID == id && (profileID == nil || item.profileID == profileID)
            }
        }
    }

    private func visibleGroups(from items: [Details.Item]) -> [SiteGroup] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return SiteGroup.groups(from: items, exceptions: model.exceptionList(for: kind))
            .filter { group in
                switch filter {
                case .all: true
                case .removable: !group.isException
                case .exceptions: group.isException
                }
            }
            .filter { query.isEmpty || $0.site.contains(query) }
            .sorted(using: sortOrder)
    }

    // MARK: Tables

    private func sitesTable(_ groups: [SiteGroup]) -> some View {
        Table(groups, selection: $selectedSites, sortOrder: $sortOrder) {
            TableColumn("Site", value: \.site) { group in
                SiteLabel(group: group)
            }
            if kind == .cache {
                TableColumn("Size", value: \.size) { group in
                    Text(group.size.formatted(.byteCount(style: .file)))
                        .monospacedDigit()
                }
                .width(min: 70, ideal: 90, max: 120)
            } else {
                TableColumn(kind == .history ? "Pages" : "Cookies", value: \.count) { group in
                    Text(group.count, format: .number)
                        .monospacedDigit()
                }
                .width(min: 60, ideal: 70, max: 100)
            }
            TableColumn(scope == .allBrowsers ? "Browsers" : "Profiles") { group in
                Text(sourceSummary(for: group))
                    .foregroundStyle(.secondary)
            }
        }
        .contextMenu(forSelectionType: String.self) { sites in
            if !sites.isEmpty {
                Button("Add to Exceptions") { model.addExceptions(sites, for: kind) }
                    .disabled(sites.allSatisfy(\.isEmpty))
                Button("Remove from Exceptions") { model.removeExceptions(coveringSites: sites, for: kind) }
                Divider()
                Button("Remove \(kind.title)…", role: .destructive) { pendingAction = .removeSites(sites) }
            }
        }
        .overlay {
            if groups.isEmpty {
                emptyState
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if let browser, model.isBlocked(kind, browserID: browser.id) {
            ContentUnavailableView {
                Label("No Access", systemImage: "lock")
            } description: {
                Text("macOS protects \(browser.name)'s \(noun). Allow CookieEater to open the folder where it's kept.")
            } actions: {
                Button("Allow Access…") { model.ensureAccess([kind], for: browser) }
            }
        } else if model.loadingKinds.contains(kind) {
            ProgressView("Reading \(noun)…")
        } else {
            ContentUnavailableView(searchText.isEmpty ? "No \(kind.title)" : "No Matching Sites",
                                   systemImage: "tray",
                                   description: Text(searchText.isEmpty ? "There's nothing to show here." : "Try a different search."))
        }
    }

    @ViewBuilder
    private func detailPane(_ items: [Details.Item]) -> some View {
        if selectedSites.isEmpty {
            ContentUnavailableView("No Site Selected", systemImage: "list.bullet.rectangle",
                                   description: Text("Select sites above to see their \(noun)."))
        } else {
            Details(items: items, selection: $selectedItems) { pendingAction = .removeItems($0) }
        }
    }

    private func actionBar(siteCount: Int, items: [Details.Item]) -> some View {
        HStack(spacing: 8) {
            Text(summary(siteCount: siteCount, items: items))
                .foregroundStyle(.secondary)
            if model.loadingKinds.contains(kind) || model.cleanupsInProgress > 0 {
                ProgressView()
                    .controlSize(.small)
            }
            if let problems = model.problems[kind], !problems.isEmpty {
                Button {
                    showsProblems = true
                } label: {
                    Label("\(problems.count) couldn't be read", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.borderless)
                .popover(isPresented: $showsProblems) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(problems, id: \.self) { Text($0) }
                    }
                    .padding()
                    .frame(maxWidth: 420, alignment: .leading)
                }
            }
            Spacer()
            Button("Add to Exceptions") { model.addExceptions(selectedSites, for: kind) }
                .disabled(selectedSites.allSatisfy(\.isEmpty))
            if selectedItems.isEmpty {
                Button("Remove Sites…") { pendingAction = .removeSites(selectedSites) }
                    .disabled(selectedSites.isEmpty)
            } else {
                Button("Remove \(kind.count(selectedItems.count))…") { pendingAction = .removeItems(selectedItems) }
            }
            Button("Remove All Not Excepted…") { pendingAction = .removeNotExcepted }
                .disabled(items.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func summary(siteCount: Int, items: [Details.Item]) -> String {
        let sites = siteCount == 1 ? "1 site" : "\(siteCount.formatted()) sites"
        var parts = [sites, kind.count(items.count)]
        if kind == .cache {
            parts.append(items.reduce(0) { $0 + $1.size }.formatted(.byteCount(style: .file)))
        }
        return parts.joined(separator: " · ")
    }

    private func sourceSummary(for group: SiteGroup) -> String {
        if let browser {
            let names = browser.profiles.filter { group.profileIDs.contains($0.id) }.map(\.name)
            return group.profileIDs.contains("") ? (names + ["Shared"]).formatted(.list(type: .and)) : names.formatted(.list(type: .and))
        }
        return model.browsers.filter { group.browserIDs.contains($0.id) }.map(\.name).formatted(.list(type: .and))
    }

    // MARK: Confirmation

    private var scopeName: String {
        guard let browser else { return "all browsers" }
        if let profileID, let profile = browser.profiles.first(where: { $0.id == profileID }) {
            return "\(browser.name) (\(profile.name))"
        }
        return browser.name
    }

    private func perform(_ action: PendingAction) {
        switch action {
        case .removeSites(let sites):
            model.remove(kind, sites: sites, scope: scope, profileID: profileID)
            selectedSites.subtract(sites)
        case .removeItems(let ids):
            model.remove(kind, itemIDs: ids)
            selectedItems.subtract(ids)
        case .removeNotExcepted:
            model.removeNotExcepted(kind, scope: scope, profileID: profileID)
        }
    }

    private func dialogTitle(for action: PendingAction) -> String {
        switch action {
        case .removeSites(let sites):
            if sites.count > 1 {
                "Remove \(noun) for \(sites.count) sites?"
            } else if let site = sites.first, !site.isEmpty {
                "Remove \(noun) for \(site)?"
            } else {
                "Remove cache files not tied to a site?"
            }
        case .removeItems(let ids):
            "Remove \(kind.count(ids.count))?"
        case .removeNotExcepted:
            model.settings[exceptionsFor: kind].isEmpty
                ? "Remove all \(noun) from \(scopeName)?"
                : "Remove all \(noun) not on the exception list from \(scopeName)?"
        }
    }

    private var dialogMessage: String {
        switch kind {
        case .history: "Visited pages are removed. Bookmarks are kept. This can't be undone."
        case .cache: "Pages may load more slowly the first time you visit them again."
        case .cookies: "You'll be signed out of the affected sites. This can't be undone."
        }
    }
}

private struct SiteLabel: View {
    let group: SiteGroup

    var body: some View {
        if group.site.isEmpty {
            Label {
                Text("Not tied to a site")
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "folder")
                    .foregroundStyle(.tertiary)
            }
        } else {
            Label {
                Text(group.site)
            } icon: {
                Image(systemName: group.isException ? "checkmark.shield.fill" : "globe")
                    .foregroundStyle(group.isException ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
            }
            .help(group.isException ? "On the exception list" : "")
        }
    }
}

private struct BrowserHeader: View {
    @Environment(AppModel.self) private var model
    let browser: InstalledBrowser
    @Binding var profileID: String?

    @State private var confirmsCleaning = false

    var body: some View {
        HStack(spacing: 12) {
            BrowserIcon(definition: browser.definition, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(browser.name)
                        .font(.title2.weight(.semibold))
                    if model.runningBrowserIDs.contains(browser.id) {
                        Text("Running")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.green.opacity(0.15), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }
                Text(DataKind.allCases.map(statistic).joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if browser.profiles.count > 1 {
                Picker("Profile", selection: $profileID) {
                    Text("All Profiles").tag(String?.none)
                    Divider()
                    ForEach(browser.profiles) { profile in
                        Text(profile.name).tag(Optional(profile.id))
                    }
                }
                .fixedSize()
            }
            Button("Clean Now") { confirmsCleaning = true }
                .disabled(!model.canClean(browser, profileID: profileID))
                .help("Remove cookies, history and cache, except for sites on the exception lists")
        }
        .padding(16)
        .confirmationDialog("Clean \(scopeName)?", isPresented: $confirmsCleaning) {
            Button("Clean", role: .destructive) { model.clean(browser, profileID: profileID) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Cookies, history and cache are removed, except for sites on the exception lists. This can't be undone.")
        }
    }

    /// "Chrome", or "Chrome (Work)" when one profile is selected.
    private var scopeName: String {
        guard let profile = browser.profiles.first(where: { $0.id == profileID }) else { return browser.name }
        return "\(browser.name) (\(profile.name))"
    }

    private func statistic(for kind: DataKind) -> String {
        if model.isBlocked(kind, browserID: browser.id) {
            return "\(kind.title): no access"
        }
        if model.loadingKinds.contains(kind) {
            return "Reading \(kind.title.lowercased())…"
        }
        let items = model.items(kind).filter { $0.browserID == browser.id && (profileID == nil || $0.profileID == profileID) }
        switch kind {
        case .cache: return "\(items.reduce(0) { $0 + $1.size }.formatted(.byteCount(style: .file))) of cache"
        case .history, .cookies: return kind.count(items.count)
        }
    }
}

/// Shown while macOS keeps CookieEater out of some of a browser's data. Only Safari's is protected.
private struct FolderAccessBanner: View {
    @Environment(AppModel.self) private var model
    let browser: InstalledBrowser

    var body: some View {
        let blocked = model.blockedKinds(browserID: browser.id)
        HStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Allow access to \(browser.name)'s \(blocked.map { $0.title.lowercased() }.formatted(.list(type: .and)))")
                    .font(.headline)
                Text("macOS protects \(browser.name)'s data, which is kept in several folders. Click Allow Access, then click Allow in each window that opens.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Allow Access…") {
                model.ensureAccess(blocked, for: browser)
            }
        }
        .padding(12)
        .background(.orange.opacity(0.08))
    }
}
