import Foundation

/// Read-only snapshots of the installed browsers and their data.
struct BrowserScan: Sendable {
    var browsers: [InstalledBrowser] = []
    var cookies: [BrowserCookie] = []
    /// What couldn't be read, by browser ID.
    var problems: [String: [String]] = [:]

    /// Lists the installed browsers and reads their cookies. Excluded browsers are listed, but their cookies are
    /// not read.
    static func perform(excluding excluded: Set<String> = []) -> BrowserScan {
        var scan = BrowserScan()
        for definition in BrowserDefinition.all where definition.isBuiltIn || FileTools.exists(definition.dataDirectory) {
            guard let browser = installed(definition) else { continue }
            scan.browsers.append(browser)
            guard !excluded.contains(definition.id) else { continue }
            let read = readCookies(of: browser)
            scan.cookies += read.items
            scan.problems[browser.id] = read.problems
        }
        return scan
    }

    static func history(of browsers: [InstalledBrowser]) -> (pages: [HistoryEntry], problems: [String: [String]]) {
        var pages: [HistoryEntry] = []
        var problems: [String: [String]] = [:]
        for browser in browsers {
            let read = readHistory(of: browser)
            pages += read.items
            problems[browser.id] = read.problems
        }
        return (pages, problems)
    }

    static func cache(of browsers: [InstalledBrowser]) -> [CacheEntry] {
        browsers.flatMap(readCache(of:))
    }

    /// Reads one browser's profiles and all of its data again. Returns nil when it no longer has any profiles.
    static func snapshot(of definition: BrowserDefinition) -> BrowserSnapshot? {
        guard let browser = installed(definition) else { return nil }
        let cookies = readCookies(of: browser)
        let history = readHistory(of: browser)
        return BrowserSnapshot(browser: browser, cookies: cookies.items, history: history.items, cache: readCache(of: browser),
                               problems: [.cookies: cookies.problems, .history: history.problems])
    }

    private static func installed(_ definition: BrowserDefinition) -> InstalledBrowser? {
        let profiles = definition.makeEngine().profiles()
        return profiles.isEmpty ? nil : InstalledBrowser(definition: definition, profiles: profiles)
    }

    private static func readCookies(of browser: InstalledBrowser) -> (items: [BrowserCookie], problems: [String]) {
        read(.cookies, of: browser, from: browser.profiles) { try $0.cookies(in: $1) }
    }

    private static func readHistory(of browser: InstalledBrowser) -> (items: [HistoryEntry], problems: [String]) {
        read(.history, of: browser, from: browser.profiles.filter { $0.historyFile != nil }) { try $0.history(in: $1) }
    }

    private static func readCache(of browser: InstalledBrowser) -> [CacheEntry] {
        isOpen(.cache, of: browser) ? browser.definition.makeEngine().cache(for: browser.profiles) : []
    }

    /// Reads one kind of data from each of these profiles, and describes the ones it couldn't be read from.
    private static func read<Item>(_ kind: DataKind, of browser: InstalledBrowser, from profiles: [BrowserProfile],
                                   _ body: (any BrowserEngine, BrowserProfile) throws -> [Item]) -> (items: [Item], problems: [String]) {
        guard isOpen(kind, of: browser) else { return ([], []) }
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
