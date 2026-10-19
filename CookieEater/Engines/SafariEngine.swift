import Foundation

/// Safari and Safari Technology Preview. Requires Full Disk Access.
///
/// Cookies live in the app container as `Cookies.binarycookies`; history lives in `History.db`
/// in ~/Library/Safari. Profiles (Safari 17+) keep their website data in `WebKit/WebsiteDataStore/<id>`.
struct SafariEngine: BrowserEngine {
    let browser: BrowserDefinition

    private var library: URL { browser.dataDirectory }

    private var historyLibrary: URL {
        URL.homeDirectory.appending(path: browser.historyPath ?? "Library/Safari", directoryHint: .isDirectory)
    }

    func profiles() -> [BrowserProfile] {
        var profiles = [
            BrowserProfile(id: "\(browser.id)/default", browserID: browser.id, name: "Default",
                           directory: library,
                           cookiesFile: library.appending(path: "Cookies/Cookies.binarycookies"),
                           historyFile: historyLibrary.appending(path: "History.db")),
        ]
        for (uuid, title) in namedProfiles() {
            let store = library.appending(path: "WebKit/WebsiteDataStore/\(uuid)", directoryHint: .isDirectory)
            let cookies = FileTools.firstFile(in: store, withExtension: "binarycookies")
            let history = [historyLibrary.appending(path: "Profiles/\(uuid)/History.db"),
                           library.appending(path: "\(historyLibrary.lastPathComponent)/Profiles/\(uuid)/History.db")]
                .first(where: FileTools.exists)
            guard cookies != nil || history != nil else { continue }
            profiles.append(BrowserProfile(id: "\(browser.id)/\(uuid)", browserID: browser.id,
                                           name: title.isEmpty ? "Profile" : title,
                                           directory: store, cookiesFile: cookies, historyFile: history))
        }
        return profiles
    }

    func cookies(in profile: BrowserProfile) throws -> [BrowserCookie] {
        guard let url = profile.cookiesFile, FileTools.exists(url) else { return [] }
        return try BinaryCookieFile(data: Data(contentsOf: url)).records.map { cookie(from: $0, in: profile) }
    }

    func removeCookies(in profile: BrowserProfile, where shouldRemove: (BrowserCookie) -> Bool) throws -> Int {
        guard let url = profile.cookiesFile, FileTools.exists(url) else { return 0 }
        var file = try BinaryCookieFile(data: Data(contentsOf: url))
        let removed = file.removeAll { shouldRemove(cookie(from: $0, in: profile)) }
        if removed > 0 {
            try file.serialized().write(to: url, options: .atomic)
        }
        return removed
    }

    func history(in profile: BrowserProfile) throws -> [HistoryEntry] {
        guard let url = profile.historyFile, FileTools.isNonEmptyFile(url) else { return [] }
        return try FileTools.readSQLiteSnapshot(url) { db in
            var pages: [HistoryEntry] = []
            try forEachPage(in: db, profile: profile) { _, page in pages.append(page) }
            return pages
        }
    }

    func removeHistory(in profile: BrowserProfile, where shouldRemove: (HistoryEntry) -> Bool) throws -> Int {
        guard let url = profile.historyFile else { return 0 }
        var ids: [Int64] = []
        var total = 0
        if FileTools.isNonEmptyFile(url) {
            let db = try SQLiteDatabase(url: url)
            try forEachPage(in: db, profile: profile) { id, page in
                total += 1
                if shouldRemove(page) { ids.append(id) }
            }
            if !ids.isEmpty {
                try db.execute("PRAGMA secure_delete = ON")
                try db.transaction {
                    try db.execute("CREATE TEMP TABLE removed_items (id INTEGER PRIMARY KEY)")
                    try db.run("INSERT INTO removed_items VALUES (?)", binding: ids)
                    for table in ["history_visits", "history_items_to_tags"] {
                        try db.deleteRows(from: table, where: "history_item", in: "SELECT id FROM removed_items")
                    }
                    try db.deleteRows(from: "history_items", where: "id", in: "SELECT id FROM removed_items")
                }
                try? db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            }
        }
        if ids.count == total {
            // Safari's own "Clear History" also forgets recently closed tabs.
            try FileTools.removeItemIfPresent(url.deletingLastPathComponent().appending(path: "RecentlyClosedTabs.plist"))
        }
        return ids.count
    }

    func cacheDirectories(for profiles: [BrowserProfile]) -> [URL] {
        browser.cacheDirectories + profiles
            .filter { $0.directory != library }
            .map { $0.directory.appending(path: "NetworkCache", directoryHint: .isDirectory) }
    }

    func cache(for profiles: [BrowserProfile]) -> [CacheEntry] {
        let roots = cacheDirectories(for: profiles)
        // WebKit keeps one "Version <n>" folder per cache format, in "WebKitCache" or directly in a profile's NetworkCache.
        let stores = roots
            .flatMap { FileTools.subdirectories(of: $0.appending(path: "WebKitCache")) + FileTools.subdirectories(of: $0) }
            .filter { $0.lastPathComponent.hasPrefix("Version ") }
        var entries: [CacheEntry] = []
        for store in stores {
            let profileID = owner(of: store, among: profiles)
            entries += CacheFormats.webKitRecords(in: store).map {
                CacheEntry(record: $0, browserID: browser.id, profileID: profileID, storeIndex: nil)
            }
        }
        return entries + looseCacheEntries(in: roots, outside: stores) { owner(of: $0, among: profiles) }
    }

    /// Named profiles keep their cache in their own folder; everything else belongs to the default profile.
    private func owner(of url: URL, among profiles: [BrowserProfile]) -> String {
        let named = profiles.first { $0.directory != library && FileTools.isItem(url, inside: $0.directory) }
        return (named ?? profiles.first { $0.directory == library })?.id ?? ""
    }

    /// Each page with the title and time of its latest visit.
    private func forEachPage(in db: SQLiteDatabase, profile: BrowserProfile, _ body: (Int64, HistoryEntry) throws -> Void) throws {
        let sql = """
            SELECT i.id, i.url, i.visit_count, v.title, v.visit_time FROM history_items i
            LEFT JOIN (SELECT history_item, title, max(visit_time) AS visit_time FROM history_visits GROUP BY history_item) v
            ON v.history_item = i.id
            """
        try db.forEachRow(sql) { row in
            let lastVisit = row.isNull(4) ? nil : Date(timeIntervalSinceReferenceDate: row.double(4))
            let page = HistoryEntry(browserID: browser.id, profileID: profile.id, rowID: row.int64(0), url: row.string(1),
                                    title: row.string(3), visitCount: Int(row.int64(2)), lastVisit: lastVisit)
            try body(row.int64(0), page)
        }
    }

    private func cookie(from record: BinaryCookieFile.Record, in profile: BrowserProfile) -> BrowserCookie {
        BrowserCookie(browserID: browser.id, profileID: profile.id, domain: record.domain, name: record.name,
                      path: record.path, expires: record.expires, isSecure: record.isSecure,
                      isHTTPOnly: record.isHTTPOnly)
    }

    /// Profiles are listed in SafariTabs.db as top-level entries with subtype 2.
    private func namedProfiles() -> [(uuid: String, title: String)] {
        let tabs = library.appending(path: "\(historyLibrary.lastPathComponent)/SafariTabs.db")
        guard FileTools.isNonEmptyFile(tabs) else { return [] }
        let profiles = try? FileTools.readSQLiteSnapshot(tabs) { db in
            var result: [(uuid: String, title: String)] = []
            try db.forEachRow("SELECT external_uuid, title FROM bookmarks WHERE parent = 0 AND subtype = 2") { row in
                let uuid = row.string(0)
                if !uuid.isEmpty, uuid != "DefaultProfile" {
                    result.append((uuid, row.string(1)))
                }
            }
            return result
        }
        return profiles ?? []
    }
}
