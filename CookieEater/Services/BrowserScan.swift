import Foundation

/// Read-only snapshots of the installed browsers and their data.
struct BrowserScan: Sendable {
    var browsers: [InstalledBrowser] = []
    var cookies: [BrowserCookie] = []
    /// What couldn't be read, by browser ID.
    var problems: [String: [String]] = [:]

    /// Lists the installed browsers and reads their cookies. Excluded browsers are listed, but their cookies are
    /// not read. Data that `running` browsers keep locked isn't read either.
    static func perform(excluding excluded: Set<String> = [], chromiumReading: DatabaseReading, running: Set<String>) -> BrowserScan {
        var scan = BrowserScan()
        for definition in BrowserDefinition.all where definition.isBuiltIn || FileTools.exists(definition.dataDirectory) {
            guard let browser = installed(definition) else { continue }
            scan.browsers.append(browser)
            guard !excluded.contains(definition.id) else { continue }
            let read = readCookies(of: browser, chromiumReading: chromiumReading, running: running)
            scan.cookies += read.items
            scan.problems[browser.id] = read.problems
        }
        return scan
    }

    static func history(of browsers: [InstalledBrowser], chromiumReading: DatabaseReading,
                        running: Set<String>) -> (pages: [HistoryEntry], problems: [String: [String]]) {
        var pages: [HistoryEntry] = []
        var problems: [String: [String]] = [:]
        for browser in browsers {
            let read = readHistory(of: browser, chromiumReading: chromiumReading, running: running)
            pages += read.items
            problems[browser.id] = read.problems
        }
        return (pages, problems)
    }

    static func cache(of browsers: [InstalledBrowser]) -> [CacheEntry] {
        browsers.flatMap(readCache(of:))
    }

    /// Reads one browser's profiles and all of its data again. Returns nil when it no longer has any profiles.
    static func snapshot(of definition: BrowserDefinition, chromiumReading: DatabaseReading, running: Set<String>) -> BrowserSnapshot? {
        guard let browser = installed(definition) else { return nil }
        let cookies = readCookies(of: browser, chromiumReading: chromiumReading, running: running)
        let history = readHistory(of: browser, chromiumReading: chromiumReading, running: running)
        return BrowserSnapshot(browser: browser, cookies: cookies.items, history: history.items, cache: readCache(of: browser),
                               problems: [.cookies: cookies.problems, .history: history.problems])
    }

    private static func installed(_ definition: BrowserDefinition) -> InstalledBrowser? {
        let profiles = definition.makeEngine().profiles()
        return profiles.isEmpty ? nil : InstalledBrowser(definition: definition, profiles: profiles)
    }

    private static func readCookies(of browser: InstalledBrowser, chromiumReading: DatabaseReading,
                                    running: Set<String>) -> (items: [BrowserCookie], problems: [String]) {
        let reading = browser.definition.databaseReading(chromium: chromiumReading)
        return read(.cookies, of: browser, from: browser.profiles, reading: reading, running: running) {
            try $0.cookies(in: $1, reading: reading)
        }
    }

    private static func readHistory(of browser: InstalledBrowser, chromiumReading: DatabaseReading,
                                    running: Set<String>) -> (items: [HistoryEntry], problems: [String]) {
        let reading = browser.definition.databaseReading(chromium: chromiumReading)
        return read(.history, of: browser, from: browser.profiles.filter { $0.historyFile != nil }, reading: reading, running: running) {
            try $0.history(in: $1, reading: reading)
        }
    }

    private static func readCache(of browser: InstalledBrowser) -> [CacheEntry] {
        isOpen(.cache, of: browser) ? browser.definition.makeEngine().cache(for: browser.profiles) : []
    }

    /// Reads one kind of data from each of these profiles, and describes the ones it couldn't be read from. Data the
    /// browser keeps locked isn't read: the app shows why instead.
    private static func read<Item>(_ kind: DataKind, of browser: InstalledBrowser, from profiles: [BrowserProfile],
                                   reading: DatabaseReading, running: Set<String>,
                                   _ body: (any BrowserEngine, BrowserProfile) throws -> [Item]) -> (items: [Item], problems: [String]) {
        guard isOpen(kind, of: browser),
              !reading.isLocked(kind, of: browser.definition, isRunning: running.contains(browser.id)) else { return ([], []) }
        let engine = browser.definition.makeEngine()
        var items: [Item] = []
        var problems: [String] = []
        for profile in profiles {
            do {
                items += try body(engine, profile)
            } catch {
                problems.append("\(label(browser, profile)): \(error.localizedDescription)")
            }
        }
        return (items, problems)
    }

    /// Whether the user has allowed CookieEater to open this data, where macOS protects it.
    private static func isOpen(_ kind: DataKind, of browser: InstalledBrowser) -> Bool {
        !browser.definition.protectedFolders(for: kind).contains(where: FileTools.isBlocked)
    }

    private static func label(_ browser: InstalledBrowser, _ profile: BrowserProfile) -> String {
        browser.profiles.count > 1 ? "\(browser.name) (\(profile.name))" : browser.name
    }
}

/// One browser's profiles and data, read again by auto sync.
struct BrowserSnapshot: Sendable {
    let browser: InstalledBrowser
    let cookies: [BrowserCookie]
    let history: [HistoryEntry]
    let cache: [CacheEntry]
    /// What couldn't be read, by kind of data.
    let problems: [DataKind: [String]]
}
