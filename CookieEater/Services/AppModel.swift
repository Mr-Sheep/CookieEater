import AppKit
import Observation
import ServiceManagement

enum CookieScope: Hashable {
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
    private(set) var stats: [String: BrowserStats] = [:]
    private(set) var problems: [String] = []
    private(set) var isLoading = false
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

    var exceptionList: ExceptionList { ExceptionList(settings.exceptions) }

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

    func browser(withID id: String) -> InstalledBrowser? {
        browsers.first { $0.id == id }
    }

    func browsers(in scope: CookieScope) -> [InstalledBrowser] {
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
    func sourceName(for cookie: BrowserCookie) -> String {
        guard let browser = browser(withID: cookie.browserID) else { return cookie.browserID }
        guard browser.profiles.count > 1, let profile = browser.profiles.first(where: { $0.id == cookie.profileID }) else {
            return browser.name
        }
        return "\(browser.name) – \(profile.name)"
    }

    func historyCount(browserID: String, profileID: String?) -> Int? {
        guard let stats = stats[browserID] else { return nil }
        if let profileID { return stats.historyItems[profileID] }
        return stats.historyItems.isEmpty ? nil : stats.historyItems.values.reduce(0, +)
    }

    var nextScheduledRun: Date? {
        let schedule = settings.schedule
        guard schedule.isEnabled else { return nil }
        let reference = max(settings.lastScheduledRun ?? schedule.anchor, schedule.anchor)
        return schedule.nextRun(after: reference)
    }

    var hasAutomaticCleanups: Bool {
        browsers.contains { settings.automation(for: $0.id).isActive }
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

    func addExceptions(_ domains: some Sequence<String>) {
        var exceptions = settings.exceptions
        for domain in domains.map(Domain.normalize) where !domain.isEmpty && !exceptions.contains(domain) {
            exceptions.append(domain)
        }
        settings.exceptions = exceptions.sorted()
    }

    func removeExceptions(_ domains: Set<String>) {
        settings.exceptions.removeAll { domains.contains($0) }
    }

    /// Removes the exceptions that cover any of the given sites.
    func removeExceptions(coveringSites sites: Set<String>) {
        settings.exceptions.removeAll { exception in
            sites.contains { $0 == exception || $0.hasSuffix("." + exception) }
        }
    }

    func setExcluded(_ excluded: Bool, browserID: String) {
        if excluded {
            settings.excludedBrowsers.insert(browserID)
            cookies.removeAll { $0.browserID == browserID }
            stats[browserID] = nil
            waitingBrowserIDs.remove(browserID)
        } else {
            settings.excludedBrowsers.remove(browserID)
        }
        // Also discards a scan that started before the change.
        Task { await reload() }
    }

    // MARK: - Folder access

    /// Asks the user to allow the protected folders that hold this kind of data, one open panel per folder.
    /// Returns whether CookieEater can open all of them.
    @discardableResult
    func ensureAccess(_ kind: DataKind, for browser: InstalledBrowser) -> Bool {
        let blocked = browser.definition.protectedFolders(for: kind).filter(FileTools.isBlocked)
        guard !blocked.isEmpty else { return true }
        let message = accessMessage(for: kind, browserName: browser.name)
        let granted = blocked.allSatisfy { folderAccess.requestAccess(to: $0, message: message) }
        if refreshAccess() {
            Task { await reload() }
        }
        return granted
    }

    private func accessMessage(for kind: DataKind, browserName: String) -> String {
        switch kind {
        case .cookies: "Click Allow to let CookieEater read and remove \(browserName)’s cookies, which are kept in this folder."
        case .history: "Click Allow to let CookieEater read and clear \(browserName)’s history."
        case .cache: "Click Allow to let CookieEater measure and clear \(browserName)’s cache."
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
            record(ActivityEntry(message: "Couldn’t change the login item", details: [error.localizedDescription], isError: true))
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
        isLoading = true
        let excluded = settings.excludedBrowsers
        let scan = await Task.detached(priority: .userInitiated) { BrowserScan.perform(excluding: excluded) }.value
        guard generation == reloadGeneration else { return }
        installedBrowsers = scan.browsers
        cookies = scan.cookies
        problems = scan.problems
        refreshAccess()
        isLoading = false

        let included = browsers
        let stats = await Task.detached(priority: .utility) {
            Dictionary(uniqueKeysWithValues: included.map { ($0.id, BrowserStats.collect(for: $0)) })
        }.value
        guard generation == reloadGeneration else { return }
        self.stats = stats
    }

    // MARK: - Manual removal

    func removeCookies(ofSites sites: Set<String>, scope: CookieScope, profileID: String?) {
        let title = sites.count == 1 ? "Removed cookies for \(sites.first!)" : "Removed cookies for \(sites.count) sites"
        submit(cookieRequests(scope: scope, profileID: profileID) { sites.contains($0.site) }, title: title)
    }

    func removeCookies(withIDs ids: Set<String>) {
        let profileIDs = Set(cookies.filter { ids.contains($0.id) }.map(\.profileID))
        let requests = browsers.compactMap { browser -> CleanupRequest? in
            let profiles = browser.profiles.filter { profileIDs.contains($0.id) }
            guard !profiles.isEmpty else { return nil }
            return CleanupRequest(browser: browser.definition, profiles: profiles, removeCookie: { ids.contains($0.id) })
        }
        submit(requests, title: ids.count == 1 ? "Removed 1 cookie" : "Removed \(ids.count) cookies")
    }

    func removeCookiesNotExcepted(scope: CookieScope, profileID: String?) {
        let exceptions = exceptionList
        submit(cookieRequests(scope: scope, profileID: profileID) { !exceptions.covers($0.host) },
               title: "Removed cookies not on the exception list")
    }

    func clearHistory(browserID: String, profileID: String?) {
        guard let browser = browser(withID: browserID) else { return }
        let profiles = browser.profiles.filter { profileID == nil || $0.id == profileID }
        submit([CleanupRequest(browser: browser.definition, profiles: profiles, clearHistory: true)],
               title: "Cleared \(browser.name) history")
    }

    func clearCache(browserID: String) {
        guard let browser = browser(withID: browserID) else { return }
        submit([CleanupRequest(browser: browser.definition, profiles: browser.profiles, clearCache: true)],
               title: "Cleared \(browser.name) cache")
    }

    func confirmQuit(_ prompt: QuitPrompt) {
        quitPrompt = nil
        Task {
            guard await quit(prompt.browsers) else {
                record(ActivityEntry(message: "\(prompt.browserNames) didn’t quit, so nothing was removed",
                                     details: ["Quit it yourself and try again."], isError: true))
                return
            }
            try? await Task.sleep(for: Self.settleDelay)
            await perform(prompt.requests, title: prompt.title)
        }
    }

    /// Requests for the profiles that currently hold matching cookies, so no browser is quit for nothing.
    private func cookieRequests(scope: CookieScope, profileID: String?,
                                where shouldRemove: @escaping @Sendable (BrowserCookie) -> Bool) -> [CleanupRequest] {
        let matchingProfileIDs = Set(cookies.filter(shouldRemove).map(\.profileID))
        return browsers(in: scope).compactMap { browser in
            let profiles = browser.profiles.filter {
                (profileID == nil || $0.id == profileID) && matchingProfileIDs.contains($0.id)
            }
            guard !profiles.isEmpty else { return nil }
            return CleanupRequest(browser: browser.definition, profiles: profiles, removeCookie: shouldRemove)
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
        var options = settings.automation(for: browser.id)
        // Data the user hasn't allowed CookieEater to open is skipped.
        for kind in blockedData[browser.id] ?? [] {
            options[kind] = false
        }
        guard options.isActive else { return nil }
        var request = CleanupRequest(browser: browser.definition, profiles: browser.profiles,
                                     clearHistory: options.history, clearCache: options.cache)
        if options.cookies {
            let exceptions = exceptionList
            request.removeCookie = { !exceptions.covers($0.host) }
        }
        return request
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
