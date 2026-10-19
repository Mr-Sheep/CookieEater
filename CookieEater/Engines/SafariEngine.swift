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

    func historyCount(in profile: BrowserProfile) throws -> Int {
        guard let url = profile.historyFile, FileTools.isNonEmptyFile(url) else { return 0 }
        return try FileTools.readSQLiteSnapshot(url) { try $0.scalarInt("SELECT count(*) FROM history_items") }
    }

    func clearHistory(in profile: BrowserProfile) throws -> Int {
        guard let url = profile.historyFile else { return 0 }
        var removed = 0
        if FileTools.isNonEmptyFile(url) {
            let db = try SQLiteDatabase(url: url)
            removed = try db.scalarInt("SELECT count(*) FROM history_items")
            try db.execute("PRAGMA secure_delete = ON")
            try db.transaction {
                for table in ["history_visits", "history_items_to_tags", "history_items"] {
                    if try db.tableExists(table) {
                        try db.execute("DELETE FROM \(table)")
                    }
                }
            }
            try? db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        }
        // Safari's own "Clear History" also forgets recently closed tabs.
        try FileTools.removeItemIfPresent(url.deletingLastPathComponent().appending(path: "RecentlyClosedTabs.plist"))
        return removed
    }

    func cacheDirectories(for profiles: [BrowserProfile]) -> [URL] {
        browser.cacheDirectories + profiles
            .filter { $0.directory != library }
            .map { $0.directory.appending(path: "NetworkCache", directoryHint: .isDirectory) }
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
