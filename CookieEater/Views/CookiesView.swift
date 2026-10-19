import SwiftUI

/// The cookies of one site, combined across the browsers and profiles in view.
struct SiteGroup: Identifiable {
    let site: String
    let isException: Bool
    var cookieCount = 0
    var browserIDs: Set<String> = []
    var profileIDs: Set<String> = []

    var id: String { site }

    static func groups(from cookies: [BrowserCookie], exceptions: ExceptionList) -> [SiteGroup] {
        var groups: [String: SiteGroup] = [:]
        for cookie in cookies {
            groups[cookie.site, default: SiteGroup(site: cookie.site, isException: exceptions.covers(cookie.site))]
                .add(cookie)
        }
        return Array(groups.values)
    }

    private mutating func add(_ cookie: BrowserCookie) {
        cookieCount += 1
        browserIDs.insert(cookie.browserID)
        profileIDs.insert(cookie.profileID)
    }
}

private enum SiteFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case removable = "Not Excepted"
    case exceptions = "Exceptions"

    var id: Self { self }
}

/// A destructive action waiting for confirmation.
private enum PendingAction: Identifiable {
    case removeSites(Set<String>)
    case removeCookies(Set<String>)
    case removeNotExcepted
    case clearHistory
    case clearCache

    var id: String {
        switch self {
        case .removeSites(let sites): "sites-\(sites.sorted())"
        case .removeCookies(let ids): "cookies-\(ids.sorted())"
        case .removeNotExcepted: "not-excepted"
        case .clearHistory: "history"
        case .clearCache: "cache"
        }
    }
}

struct CookiesView: View {
    @Environment(AppModel.self) private var model
    let scope: CookieScope

    @State private var profileID: String?
    @State private var searchText = ""
    @State private var filter = SiteFilter.all
    @State private var selectedSites = Set<String>()
    @State private var selectedCookies = Set<String>()
    @State private var sortOrder = [KeyPathComparator(\SiteGroup.site)]
    @State private var pendingAction: PendingAction?
    @State private var showsProblems = false

    private var browser: InstalledBrowser? {
        if case .browser(let id) = scope { model.browser(withID: id) } else { nil }
    }

    private var scopeName: String {
        guard let browser else { return "all browsers" }
        if let profileID, let profile = browser.profiles.first(where: { $0.id == profileID }) {
            return "\(browser.name) (\(profile.name))"
        }
        return browser.name
    }

    var body: some View {
        let cookies = scopedCookies
        let groups = visibleGroups(from: cookies)
        VStack(spacing: 0) {
            ForEach(model.browsers(in: scope).filter { !model.blockedKinds(browserID: $0.id).isEmpty }) { browser in
                FolderAccessBanner(browser: browser)
                Divider()
            }
            if let browser {
                BrowserHeader(browser: browser, profileID: $profileID,
                              clearHistory: {
                                  if model.ensureAccess([.history], for: browser) { pendingAction = .clearHistory }
                              },
                              clearCache: {
                                  if model.ensureAccess([.cache], for: browser) { pendingAction = .clearCache }
                              })
                Divider()
            }
            // Without a flexible width, the split view starts at the tables' ideal width.
            VSplitView {
                sitesTable(groups)
                    .frame(maxWidth: .infinity, minHeight: 180, idealHeight: 340, maxHeight: .infinity)
                cookieTable(cookies.filter { selectedSites.contains($0.site) })
                    .frame(maxWidth: .infinity, minHeight: 120, idealHeight: 200, maxHeight: .infinity)
            }
            Divider()
            actionBar(siteCount: groups.count, cookieCount: cookies.count)
        }
        .navigationTitle(browser?.name ?? "All Browsers")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Filter Sites")
        .toolbar {
            ToolbarItem {
                Picker("Show", selection: $filter) {
                    ForEach(SiteFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem {
                Button("Reload", systemImage: "arrow.clockwise") {
                    Task { await model.reload() }
                }
                .disabled(model.isLoading)
            }
        }
        .onChange(of: selectedSites) {
            selectedCookies = []
        }
        .onChange(of: profileID) {
            selectedSites = []
        }
        .confirmationDialog(pendingAction.map(dialogTitle) ?? "",
                            isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }),
                            presenting: pendingAction) { action in
            Button(confirmLabel(for: action), role: .destructive) { perform(action) }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(dialogMessage(for: action))
        }
    }

    private var scopedCookies: [BrowserCookie] {
        model.cookies.filter { cookie in
            switch scope {
            case .allBrowsers: true
            case .browser(let id): cookie.browserID == id && (profileID == nil || cookie.profileID == profileID)
            }
        }
    }

    private func visibleGroups(from cookies: [BrowserCookie]) -> [SiteGroup] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return SiteGroup.groups(from: cookies, exceptions: model.exceptionList)
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
                Label {
                    Text(group.site)
                } icon: {
                    Image(systemName: group.isException ? "checkmark.shield.fill" : "globe")
                        .foregroundStyle(group.isException ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                }
                .help(group.isException ? "On the exception list" : "")
            }
            TableColumn("Cookies", value: \.cookieCount) { group in
                Text(group.cookieCount, format: .number)
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 70, max: 100)
            TableColumn(scope == .allBrowsers ? "Browsers" : "Profiles") { group in
                Text(sourceSummary(for: group))
                    .foregroundStyle(.secondary)
            }
        }
        .contextMenu(forSelectionType: String.self) { sites in
            if !sites.isEmpty {
                Button("Add to Exceptions") { model.addExceptions(sites) }
                Button("Remove from Exceptions") { model.removeExceptions(coveringSites: sites) }
                Divider()
                Button("Remove Cookies…", role: .destructive) { pendingAction = .removeSites(sites) }
            }
        }
        .overlay {
            if groups.isEmpty && !model.isLoading {
                ContentUnavailableView(searchText.isEmpty ? "No Cookies" : "No Matching Sites",
                                       systemImage: "tray",
                                       description: Text(searchText.isEmpty ? "There are no cookies to show here." : "Try a different search."))
            }
        }
    }

    @ViewBuilder
    private func cookieTable(_ cookies: [BrowserCookie]) -> some View {
        if selectedSites.isEmpty {
            ContentUnavailableView("No Site Selected", systemImage: "list.bullet.rectangle",
                                   description: Text("Select sites above to see their cookies."))
        } else {
            Table(cookies, selection: $selectedCookies) {
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
                if !ids.isEmpty {
                    Button("Remove Cookies…", role: .destructive) { pendingAction = .removeCookies(ids) }
                }
            }
        }
    }

    private func actionBar(siteCount: Int, cookieCount: Int) -> some View {
        HStack(spacing: 8) {
            Text("\(siteCount.formatted()) sites · \(cookieCount.formatted()) cookies")
                .foregroundStyle(.secondary)
            if model.isLoading || model.cleanupsInProgress > 0 {
                ProgressView()
                    .controlSize(.small)
            }
            if !model.problems.isEmpty {
                Button {
                    showsProblems = true
                } label: {
                    Label("\(model.problems.count) couldn’t be read", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.borderless)
                .popover(isPresented: $showsProblems) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.problems, id: \.self) { Text($0) }
                    }
                    .padding()
                    .frame(maxWidth: 420, alignment: .leading)
                }
            }
            Spacer()
            Button("Add to Exceptions") { model.addExceptions(selectedSites) }
                .disabled(selectedSites.isEmpty)
            if selectedCookies.isEmpty {
                Button("Remove Sites…") { pendingAction = .removeSites(selectedSites) }
                    .disabled(selectedSites.isEmpty)
            } else {
                Button("Remove Cookies…") { pendingAction = .removeCookies(selectedCookies) }
            }
            Button("Remove All Not Excepted…") { pendingAction = .removeNotExcepted }
                .disabled(cookieCount == 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func sourceSummary(for group: SiteGroup) -> String {
        if let browser {
            return browser.profiles.filter { group.profileIDs.contains($0.id) }.map(\.name).formatted(.list(type: .and))
        }
        return model.browsers.filter { group.browserIDs.contains($0.id) }.map(\.name).formatted(.list(type: .and))
    }

    // MARK: Confirmation

    private func perform(_ action: PendingAction) {
        switch action {
        case .removeSites(let sites):
            model.removeCookies(ofSites: sites, scope: scope, profileID: profileID)
            selectedSites.subtract(sites)
        case .removeCookies(let ids):
            model.removeCookies(withIDs: ids)
            selectedCookies.subtract(ids)
        case .removeNotExcepted:
            model.removeCookiesNotExcepted(scope: scope, profileID: profileID)
        case .clearHistory:
            if let browser { model.clearHistory(browserID: browser.id, profileID: profileID) }
        case .clearCache:
            if let browser { model.clearCache(browserID: browser.id) }
        }
    }

    private func dialogTitle(for action: PendingAction) -> String {
        switch action {
        case .removeSites(let sites):
            sites.count == 1 ? "Remove cookies for \(sites.first!)?" : "Remove cookies for \(sites.count) sites?"
        case .removeCookies(let ids):
            ids.count == 1 ? "Remove this cookie?" : "Remove \(ids.count) cookies?"
        case .removeNotExcepted:
            "Remove all cookies not on the exception list from \(scopeName)?"
        case .clearHistory:
            "Clear browsing history for \(scopeName)?"
        case .clearCache:
            "Clear the cache for \(browser?.name ?? "this browser")?"
        }
    }

    private func dialogMessage(for action: PendingAction) -> String {
        switch action {
        case .removeSites, .removeCookies, .removeNotExcepted:
            "You’ll be signed out of the affected sites. This can’t be undone."
        case .clearHistory:
            "Visited pages and search terms are removed. Bookmarks are kept. This can’t be undone."
        case .clearCache:
            "Pages may load more slowly the first time you visit them again."
        }
    }

    private func confirmLabel(for action: PendingAction) -> String {
        switch action {
        case .removeSites, .removeCookies, .removeNotExcepted: "Remove"
        case .clearHistory, .clearCache: "Clear"
        }
    }
}

private struct BrowserHeader: View {
    @Environment(AppModel.self) private var model
    let browser: InstalledBrowser
    @Binding var profileID: String?
    let clearHistory: () -> Void
    let clearCache: () -> Void

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
                Text(statistics)
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
            Button("Clear History…", action: clearHistory)
            Button("Clear Cache…", action: clearCache)
        }
        .padding(16)
    }

    private var statistics: String {
        guard let stats = model.stats[browser.id] else { return "Measuring history and cache…" }
        let history = if model.isBlocked(.history, browserID: browser.id) {
            "History: no access"
        } else {
            model.historyCount(browserID: browser.id, profileID: profileID)
                .map { "History: \($0.formatted()) pages" } ?? "History: unavailable"
        }
        let cache = model.isBlocked(.cache, browserID: browser.id)
            ? "Cache: no access" : "Cache: \(stats.cacheBytes.formatted(.byteCount(style: .file)))"
        return "\(history) · \(cache)"
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
                Text("Allow access to \(browser.name)’s \(blocked.map(name).formatted(.list(type: .and)))")
                    .font(.headline)
                Text("macOS protects \(browser.name)’s data, which is kept in several folders. Click Allow Access, then click Allow in each window that opens.")
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

    private func name(_ kind: DataKind) -> String {
        switch kind {
        case .cookies: "cookies"
        case .history: "history"
        case .cache: "cache"
        }
    }
}
