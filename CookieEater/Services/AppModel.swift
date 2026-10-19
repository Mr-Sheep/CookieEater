import AppKit
import Observation
import ServiceManagement

enum BrowserScope: Hashable {
    case allBrowsers
    case browser(String)
}

/// Shown when data has to be removed from a browser that is still open.
struct QuitPrompt: Identifiable {
    let id = UUID()
    let browsers: [BrowserDefinition]
    let requests: [CleanupRequest]
    let title: String

    var browserNames: String {
        browsers.map(\.name).formatted(.list(type: .and))
    }
}

@MainActor
@Observable
final class AppModel {
    /// How long to wait after a browser quits before touching its files, so it can finish writing them.
    private static let settleDelay = Duration.seconds(3)

    /// Every supported browser with data on this Mac, including excluded ones.
    private(set) var installedBrowsers: [InstalledBrowser] = []
    private(set) var cookies: [BrowserCookie] = []
    private(set) var history: [HistoryEntry] = []
    private(set) var cache: [CacheEntry] = []
    /// Data still being read. Cookies are read first, then history, then the cache.
    private(set) var loadingKinds: Set<DataKind> = []
    /// What couldn't be read, by kind of data.
    private(set) var problems: [DataKind: [String]] = [:]
    private(set) var cleanupsInProgress = 0
    private(set) var runningBrowserIDs: Set<String> = []
    /// Browsers whose scheduled cleanup is waiting for them to quit.
    private(set) var waitingBrowserIDs: Set<String> = []
    private(set) var activity: [ActivityEntry]
    /// Data macOS doesn't let CookieEater open yet, by browser ID. Only Safari's data is protected.
    private(set) var blockedData: [String: Set<DataKind>] = [:]
    private(set) var launchAtLogin = false
    var quitPrompt: QuitPrompt?

    var settings: AppSettings {
        didSet {
            if settings != oldValue { SettingsStore.save(settings) }
        }
    }

    @ObservationIgnored private let worker = CleanupWorker()
    @ObservationIgnored private let folderAccess = FolderAccess()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var scheduleTimer: Timer?
    @ObservationIgnored private var reloadGeneration = 0

    init() {
        settings = SettingsStore.loadSettings()
        activity = SettingsStore.loadActivity()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        refreshRunningBrowsers()
        startObserving()
        startScheduleTimer()
        Task { await reload() }
    }

    // MARK: - Queries

    var isLoading: Bool { !loadingKinds.isEmpty }

    func exceptionList(for kind: DataKind) -> ExceptionList {
        ExceptionList(settings[exceptionsFor: kind])
    }

    /// One kind of data, from every browser that isn't excluded.
    func items(_ kind: DataKind) -> [any SiteData] {
        switch kind {
        case .history: history
        case .cache: cache
        case .cookies: cookies
        }
    }

    /// The browsers CookieEater shows and cleans: every installed browser that isn't excluded.
    var browsers: [InstalledBrowser] {
        installedBrowsers.filter { !settings.excludedBrowsers.contains($0.id) }
    }

    func isExcluded(_ browserID: String) -> Bool {
        settings.excludedBrowsers.contains(browserID)
    }

    func isBlocked(_ kind: DataKind, browserID: String) -> Bool {
        blockedData[browserID]?.contains(kind) ?? false
    }

    func blockedKinds(browserID: String) -> [DataKind] {
        DataKind.allCases.filter { isBlocked($0, browserID: browserID) }
    }

    func browser(withID id: String) -> InstalledBrowser? {
        browsers.first { $0.id == id }
    }

    func browsers(in scope: BrowserScope) -> [InstalledBrowser] {
        switch scope {
        case .allBrowsers: browsers
        case .browser(let id): browsers.filter { $0.id == id }
        }
    }

    func isRunning(_ browser: BrowserDefinition) -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            app.bundleIdentifier.map(browser.bundleIDs.contains) ?? false
        }
    }

    /// "Chrome", or "Chrome – Work" when the browser has several profiles.
    func sourceName(for item: some SiteData) -> String {
        guard let browser = browser(withID: item.browserID) else { return item.browserID }
        guard browser.profiles.count > 1, let profile = browser.profiles.first(where: { $0.id == item.profileID }) else {
            return browser.name
        }
        return "\(browser.name) – \(profile.name)"
    }

    var nextScheduledRun: Date? {
        let schedule = settings.schedule
        guard schedule.isEnabled else { return nil }
        let reference = max(settings.lastScheduledRun ?? schedule.anchor, schedule.anchor)
        return schedule.nextRun(after: reference)
    }

    var hasAutomaticCleanups: Bool {
        browsers.contains { browser in
            let options = settings.automation(for: browser.id)
            return options.isActive && browser.profiles.contains(where: options.cleans)
        }
    }

    // MARK: - Settings

    /// Editing the schedule restarts it from now, so a change never triggers a cleanup straight away.
    var schedule: CleanupSchedule {
        get { settings.schedule }
        set {
            var schedule = newValue
            schedule.anchor = .now
            settings.schedule = schedule
        }
    }

    func addExceptions(_ domains: some Sequence<String>, for kind: DataKind) {
        var exceptions = settings[exceptionsFor: kind]
        for domain in domains.map(Domain.normalize) where !domain.isEmpty && !exceptions.contains(domain) {
            exceptions.append(domain)
        }
        settings[exceptionsFor: kind] = exceptions.sorted()
    }

    func removeExceptions(_ domains: Set<String>, for kind: DataKind) {
        settings[exceptionsFor: kind].removeAll { domains.contains($0) }
    }

    /// Removes the exceptions that cover any of the given sites.
    func removeExceptions(coveringSites sites: Set<String>, for kind: DataKind) {
        settings[exceptionsFor: kind].removeAll { exception in
            sites.contains { $0 == exception || $0.hasSuffix("." + exception) }
        }
    }

    func setExcluded(_ excluded: Bool, browserID: String) {
        if excluded {
            settings.excludedBrowsers.insert(browserID)
            cookies.removeAll { $0.browserID == browserID }
            history.removeAll { $0.browserID == browserID }
            cache.removeAll { $0.browserID == browserID }
            waitingBrowserIDs.remove(browserID)
        } else {
            settings.excludedBrowsers.remove(browserID)
        }
        // Also discards a scan that started before the change.
        Task { await reload() }
    }

    // MARK: - Folder access

    /// Asks the user to allow the protected folders that hold these kinds of data, one open panel per folder,
    /// stopping at the first one they don't allow. Returns whether CookieEater can open all of them.
    @discardableResult
    func ensureAccess(_ kinds: [DataKind], for browser: InstalledBrowser) -> Bool {
        var requests: [(folder: URL, kind: DataKind)] = []
        for kind in kinds {
            for folder in browser.definition.protectedFolders(for: kind)
            where FileTools.isBlocked(folder) && !requests.contains(where: { $0.folder == folder }) {
                requests.append((folder, kind))
            }
        }
        // Allowing a folder also allows everything inside it, such as the cache in Safari's data folder.
        let folders = requests.map(\.folder)
        requests = requests.filter { request in
            !folders.contains { $0 != request.folder && FileTools.isItem(request.folder, inside: $0) }
        }
        guard !requests.isEmpty else { return true }

        var granted = true
        for (index, request) in requests.enumerated() {
            let step = requests.count > 1 ? "Folder \(index + 1) of \(requests.count). " : ""
            let message = step + accessMessage(for: request.kind, browserName: browser.name)
            guard folderAccess.requestAccess(to: request.folder, message: message) else {
                granted = false
                break
            }
        }
        if refreshAccess() {
            Task { await reload() }
        }
        return granted
    }

    private func accessMessage(for kind: DataKind, browserName: String) -> String {
        switch kind {
        case .cookies: "Click Allow to let CookieEater read and remove \(browserName)'s cookies, which are kept in this folder."
        case .history: "Click Allow to let CookieEater read and clear \(browserName)'s history."
        case .cache: "Click Allow to let CookieEater measure and clear \(browserName)'s cache."
        }
    }

    /// Returns whether anything changed.
    @discardableResult
    private func refreshAccess() -> Bool {
        var blocked: [String: Set<DataKind>] = [:]
        for browser in installedBrowsers {
            let kinds = DataKind.allCases.filter { kind in
                browser.definition.protectedFolders(for: kind).contains(where: FileTools.isBlocked)
            }
            if !kinds.isEmpty {
                blocked[browser.id] = Set(kinds)
            }
        }
        guard blocked != blockedData else { return false }
        blockedData = blocked
        return true
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            record(ActivityEntry(message: "Couldn't change the login item", details: [error.localizedDescription], isError: true))
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    var loginItemNeedsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    func clearActivity() {
        activity = []
        SettingsStore.save(activity)
    }

    // MARK: - Loading

    func reload() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        loadingKinds = Set(DataKind.allCases)
        let excluded = settings.excludedBrowsers
        let scan = await Task.detached(priority: .userInitiated) { BrowserScan.perform(excluding: excluded) }.value
        guard generation == reloadGeneration else { return }
        installedBrowsers = scan.browsers
        cookies = scan.cookies
        problems[.cookies] = scan.problems
        refreshAccess()
        loadingKinds.remove(.cookies)

        let included = browsers
        let history = await Task.detached(priority: .utility) { BrowserScan.history(of: included) }.value
        guard generation == reloadGeneration else { return }
        self.history = history.pages
        problems[.history] = history.problems
        loadingKinds.remove(.history)

        let cache = await Task.detached(priority: .utility) { BrowserScan.cache(of: included) }.value
        guard generation == reloadGeneration else { return }
        self.cache = cache
        loadingKinds.remove(.cache)
    }

    // MARK: - Manual removal

    func remove(_ kind: DataKind, sites: Set<String>, scope: BrowserScope, profileID: String?) {
        let what = sites.count == 1 ? (sites.first!.isEmpty ? "files not tied to a site" : sites.first!) : "\(sites.count) sites"
        submit(requests(kind, scope: scope, profileID: profileID) { sites.contains($0.site) },
               title: "Removed \(kind.title.lowercased()) for \(what)")
    }

    func remove(_ kind: DataKind, itemIDs ids: Set<String>) {
        submit(requests(kind, scope: .allBrowsers, profileID: nil) { ids.contains($0.id) },
               title: "Removed \(kind.count(ids.count))")
    }

    func removeNotExcepted(_ kind: DataKind, scope: BrowserScope, profileID: String?) {
        let exceptions = exceptionList(for: kind)
        submit(requests(kind, scope: scope, profileID: profileID) { !exceptions.covers($0.host) },
               title: "Removed \(kind.title.lowercased()) not on the exception list")
    }

    /// Whether `clean(_:profileID:)` has anything to remove.
    func canClean(_ browser: InstalledBrowser, profileID: String?) -> Bool {
        cleanRequest(for: browser, profileID: profileID) != nil
    }

    /// Removes every kind of data that isn't on its exception list from a browser, or from one of its profiles.
    func clean(_ browser: InstalledBrowser, profileID: String?) {
        guard let request = cleanRequest(for: browser, profileID: profileID) else { return }
        let profile = browser.profiles.first { $0.id == profileID }
        submit([request], title: "Cleaned \(profile.map { "\(browser.name) (\($0.name))" } ?? browser.name)")
    }

    private func cleanRequest(for browser: InstalledBrowser, profileID: String?) -> CleanupRequest? {
        // When cleaning one profile, the others' files aren't touched.
        let otherProfiles = profileID == nil ? [] : Set(browser.profiles.map(\.id).filter { $0 != profileID })
        var request = CleanupRequest(browser: browser.definition, profiles: browser.profiles,
                                     skippedProfileIDs: otherProfiles)
        for kind in DataKind.allCases {
            let exceptions = exceptionList(for: kind)
            let shouldRemove: @Sendable (any SiteData) -> Bool = { item in
                (profileID == nil || item.profileID == profileID) && !exceptions.covers(item.host)
            }
            // Kinds with nothing to remove are left out, so an open browser isn't quit for nothing.
            if items(kind).contains(where: { $0.browserID == browser.id && shouldRemove($0) }) {
                request.removals[kind] = shouldRemove
            }
        }
        return request.removals.isEmpty ? nil : request
    }

    // MARK: - Cookie values

    /// Puts cookies and their values on the clipboard. This is the only place cookie values are read.
    /// Cookies that no longer exist are left out.
    func copy(_ cookies: [BrowserCookie], as format: CookieCopyFormat) async throws {
        let sources = Dictionary(grouping: cookies, by: \.profileID).compactMap { profileID, cookies in
            browser(withID: cookies[0].browserID).flatMap { browser in
                browser.profiles.first { $0.id == profileID }.map { (engine: browser.definition.makeEngine(), profile: $0, cookies: cookies) }
            }
        }
        let values = try await Task.detached(priority: .userInitiated) {
            try sources.reduce(into: [String: String]()) { values, source in
                values.merge(try source.engine.cookieValues(of: source.cookies, in: source.profile)) { $1 }
            }
        }.value
        guard !values.isEmpty else {
            throw CookieValueError(cookies.count == 1 ? "The cookie no longer exists. Reload to see the current cookies."
                                                      : "These cookies no longer exist. Reload to see the current cookies.")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(format.text(for: cookies, values: values), forType: .string)
    }

    func confirmQuit(_ prompt: QuitPrompt) {
        quitPrompt = nil
        Task {
            guard await quit(prompt.browsers) else {
                record(ActivityEntry(message: "\(prompt.browserNames) didn't quit, so nothing was removed",
                                     details: ["Quit it yourself and try again."], isError: true))
                return
            }
            try? await Task.sleep(for: Self.settleDelay)
            await perform(prompt.requests, title: prompt.title)
        }
    }

    /// Requests for the browsers and profiles that currently hold matching items, so no browser is quit for nothing.
    private func requests(_ kind: DataKind, scope: BrowserScope, profileID: String?,
                          where matches: @escaping @Sendable (any SiteData) -> Bool) -> [CleanupRequest] {
        let shouldRemove: @Sendable (any SiteData) -> Bool = { item in
            (profileID == nil || item.profileID == profileID) && matches(item)
        }
        let matching = items(kind).filter(shouldRemove)
        return browsers(in: scope).compactMap { browser in
            let profileIDs = Set(matching.filter { $0.browserID == browser.id }.map(\.profileID))
            guard !profileIDs.isEmpty else { return nil }
            // The cache is always listed for every profile, so shared cache folders are attributed correctly.
            let profiles = kind == .cache ? browser.profiles : browser.profiles.filter { profileIDs.contains($0.id) }
            var request = CleanupRequest(browser: browser.definition, profiles: profiles)
            request.removals[kind] = shouldRemove
            return request
        }
    }

    /// Runs the requests now, or first asks to quit the browsers that are open.
    private func submit(_ requests: [CleanupRequest], title: String) {
        guard !requests.isEmpty else { return }
        let running = requests.map(\.browser).filter(isRunning)
        if running.isEmpty {
            Task { await perform(requests, title: title) }
        } else {
            quitPrompt = QuitPrompt(browsers: running, requests: requests, title: title)
        }
    }

    private func quit(_ browsers: [BrowserDefinition]) async -> Bool {
        let bundleIDs = Set(browsers.flatMap(\.bundleIDs))
        func runningApps() -> [NSRunningApplication] {
            NSWorkspace.shared.runningApplications.filter { bundleIDs.contains($0.bundleIdentifier ?? "") }
        }
        let requestsSent = runningApps().map { $0.terminate() }
        if !requestsSent.isEmpty && !requestsSent.contains(true) {
            return false
        }
        // Give the browsers time to close their windows; they may ask the user to confirm.
        for _ in 0..<120 {
            if runningApps().isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return runningApps().isEmpty
    }

    private func perform(_ requests: [CleanupRequest], title: String) async {
        cleanupsInProgress += 1
        var reports: [CleanupReport] = []
        for request in requests {
            reports.append(await worker.perform(request))
        }
        cleanupsInProgress -= 1

        let details = reports.map { "\($0.browserName): \($0.summary)" }
        let errors = reports.flatMap { report in report.errors.map { "\(report.browserName) – \($0)" } }
        record(ActivityEntry(message: title, details: details + errors, isError: !errors.isEmpty))
        await reload()
    }

    // MARK: - Automatic cleanup

    func cleanNow() {
        runAutomaticCleanup(title: "Cleaned now")
    }

    private func automaticRequest(for browser: InstalledBrowser) -> CleanupRequest? {
        let options = settings.automation(for: browser.id)
        guard browser.profiles.contains(where: options.cleans) else { return nil }
        var request = CleanupRequest(browser: browser.definition, profiles: browser.profiles,
                                     skippedProfileIDs: options.skippedProfiles)
        // Data the user hasn't allowed CookieEater to open is skipped.
        for kind in DataKind.allCases where options[kind] && !isBlocked(kind, browserID: browser.id) {
            let exceptions = exceptionList(for: kind)
            request.removals[kind] = { !exceptions.covers($0.host) }
        }
        return request.removals.isEmpty ? nil : request
    }

    /// Cleans every browser that has automatic cleanup turned on. Open browsers are cleaned once they quit.
    private func runAutomaticCleanup(title: String) {
        var requests: [CleanupRequest] = []
        var deferred: [String] = []
        for browser in browsers {
            guard let request = automaticRequest(for: browser) else { continue }
            if isRunning(browser.definition) {
                if waitingBrowserIDs.insert(browser.id).inserted {
                    deferred.append(browser.name)
                }
            } else {
                requests.append(request)
            }
        }
        if !deferred.isEmpty {
            record(ActivityEntry(message: "Waiting for \(deferred.formatted(.list(type: .and))) to quit",
                                 details: ["Open browsers are cleaned as soon as they quit."]))
        }
        if !requests.isEmpty {
            Task { await perform(requests, title: title) }
        }
    }

    private func applicationDidTerminate(bundleID: String?) {
        refreshRunningBrowsers()
        guard let bundleID, let browser = browsers.first(where: { $0.definition.bundleIDs.contains(bundleID) }) else {
            return
        }
        let wasWaiting = waitingBrowserIDs.contains(browser.id)
        Task {
            try? await Task.sleep(for: Self.settleDelay)
            // Another app sharing this data folder is still open, or the browser was reopened.
            guard !isRunning(browser.definition) else { return }
            waitingBrowserIDs.remove(browser.id)
            if wasWaiting || settings.cleanOnQuit, let request = automaticRequest(for: browser) {
                await perform([request], title: wasWaiting ? "Scheduled cleanup after \(browser.name) quit" : "\(browser.name) quit")
            } else {
                // The browser wrote its data out when it quit.
                await reload()
            }
        }
    }

    private func checkSchedule() {
        guard let next = nextScheduledRun, next <= .now else { return }
        settings.lastScheduledRun = .now
        runAutomaticCleanup(title: "Scheduled cleanup")
    }

    // MARK: - Activity

    private func record(_ entry: ActivityEntry) {
        activity.insert(entry, at: 0)
        if activity.count > 200 {
            activity.removeLast(activity.count - 200)
        }
        SettingsStore.save(activity)
    }

    // MARK: - System events

    private func refreshRunningBrowsers() {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        runningBrowserIDs = Set(BrowserDefinition.all.filter { !running.isDisjoint(with: $0.bundleIDs) }.map(\.id))
    }

    private func startObserving() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                               object: nil, queue: .main) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { self?.applicationDidTerminate(bundleID: bundleID) }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshRunningBrowsers() }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSchedule() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applicationDidBecomeActive() }
        })
    }

    /// The user may have just approved the login item, or changed CookieEater's access, in System Settings.
    private func applicationDidBecomeActive() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if refreshAccess() {
            Task { await reload() }
        }
    }

    private func startScheduleTimer() {
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSchedule() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        scheduleTimer = timer
    }
}
