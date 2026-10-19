import Foundation

/// Firefox and browsers built on it (Zen, LibreWolf, Waterfox, …).
///
/// Profiles are listed in `profiles.ini`. Each profile folder holds `cookies.sqlite` and `places.sqlite`
/// (history and bookmarks); the cache lives in ~/Library/Caches/<browser>/Profiles/<profile>.
struct FirefoxEngine: BrowserEngine {
    let browser: BrowserDefinition

    func profiles() -> [BrowserProfile] {
        let root = browser.dataDirectory
        guard let ini = try? String(contentsOf: root.appending(path: "profiles.ini"), encoding: .utf8) else { return [] }

        var profiles: [BrowserProfile] = []
        var seen = Set<String>()
        func add(path: String, isRelative: Bool, name: String?) {
            guard !path.isEmpty else { return }
            let directory = isRelative
                ? root.appending(path: path, directoryHint: .isDirectory)
                : URL(filePath: path, directoryHint: .isDirectory)
            guard FileTools.exists(directory), seen.insert(directory.standardizedFileURL.path).inserted else { return }
            let folder = directory.lastPathComponent
            // Folders are named "<salt>.<name>", e.g. "x8d6wrmf.default-release".
            let displayName = name ?? folder.split(separator: ".", maxSplits: 1).last.map(String.init) ?? folder
            let cookies = directory.appending(path: "cookies.sqlite")
            let places = directory.appending(path: "places.sqlite")
            profiles.append(BrowserProfile(id: "\(browser.id)/\(folder)", browserID: browser.id, name: displayName,
                                           directory: directory,
                                           cookiesFile: FileTools.exists(cookies) ? cookies : nil,
                                           historyFile: FileTools.exists(places) ? places : nil))
        }

        let sections = Self.parseINI(ini)
        for (section, values) in sections where section.hasPrefix("Profile") {
            add(path: values["Path"] ?? "", isRelative: values["IsRelative"] != "0", name: values["Name"])
        }
        // Each installation's default profile, which may not have a [Profile] section of its own.
        for (section, values) in sections where !section.hasPrefix("Profile") {
            if let path = values["Default"] {
                add(path: path, isRelative: !path.hasPrefix("/"), name: nil)
            }
        }
        return profiles
    }

    func cookies(in profile: BrowserProfile) throws -> [BrowserCookie] {
        guard let url = profile.cookiesFile else { return [] }
        return try FileTools.readSQLiteSnapshot(url) { db in
            var cookies: [BrowserCookie] = []
            try forEachCookie(in: db, profile: profile) { _, cookie in cookies.append(cookie) }
            return cookies
        }
    }

    func removeCookies(in profile: BrowserProfile, where shouldRemove: (BrowserCookie) -> Bool) throws -> Int {
        guard let url = profile.cookiesFile else { return 0 }
        let db = try SQLiteDatabase(url: url)
        var ids: [Int64] = []
        try forEachCookie(in: db, profile: profile) { id, cookie in
            if shouldRemove(cookie) { ids.append(id) }
        }
        guard !ids.isEmpty else { return 0 }
        try db.execute("PRAGMA secure_delete = ON")
        try db.transaction {
            try db.run("DELETE FROM moz_cookies WHERE id = ?", binding: ids)
        }
        try? db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        return ids.count
    }

    func cookieValues(of cookies: [BrowserCookie], in profile: BrowserProfile) throws -> [String: String] {
        guard let url = profile.cookiesFile else { return [:] }
        let wanted = Set(cookies.map(\.id))
        return try FileTools.readSQLiteSnapshot(url) { db in
            var values: [String: String] = [:]
            try forEachCookie(in: db, profile: profile) { id, cookie in
                guard wanted.contains(cookie.id) else { return }
                try db.forEachRow("SELECT value FROM moz_cookies WHERE id = ?", binding: id) { values[cookie.id] = $0.string(0) }
            }
            return values
        }
    }

    func history(in profile: BrowserProfile) throws -> [HistoryEntry] {
        guard let url = profile.historyFile else { return [] }
        return try FileTools.readSQLiteSnapshot(url) { db in
            var pages: [HistoryEntry] = []
            try forEachPage(in: db, profile: profile) { _, page in pages.append(page) }
            return pages
        }
    }

    func removeHistory(in profile: BrowserProfile, where shouldRemove: (HistoryEntry) -> Bool) throws -> Int {
        guard let url = profile.historyFile else { return 0 }
        let db = try SQLiteDatabase(url: url)
        var ids: [Int64] = []
        var total = 0
        try forEachPage(in: db, profile: profile) { id, page in
            total += 1
            if shouldRemove(page) { ids.append(id) }
        }
        try db.execute("PRAGMA secure_delete = ON")
        if ids.count == total {
            try clearAllHistory(in: db)
        } else if !ids.isEmpty {
            try db.transaction {
                try db.execute("CREATE TEMP TABLE removed_places (id INTEGER PRIMARY KEY)")
                try db.run("INSERT INTO removed_places VALUES (?)", binding: ids)
                let places = "SELECT id FROM removed_places"
                try db.deleteRows(from: "moz_historyvisits_extra", where: "visit_id",
                                  in: "SELECT id FROM moz_historyvisits WHERE place_id IN (\(places))")
                for table in ["moz_historyvisits", "moz_inputhistory", "moz_places_metadata"] {
                    try db.deleteRows(from: table, where: "place_id", in: places)
                }
                // Bookmarked pages stay, without their visits; the others only existed because of history.
                let unreferenced = "SELECT id FROM moz_places WHERE foreign_count = 0 AND id IN (\(places))"
                for table in ["moz_annos", "moz_places_extra"] {
                    try db.deleteRows(from: table, where: "place_id", in: unreferenced)
                }
                try db.deleteRows(from: "moz_places", where: "id", in: unreferenced)
                try db.execute("UPDATE moz_places SET visit_count = 0, last_visit_date = NULL, frecency = 0 WHERE id IN (\(places))")
                try removeUnusedOrigins(in: db)
            }
        }
        try? db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        return ids.count
    }

    private func clearAllHistory(in db: SQLiteDatabase) throws {
        try db.transaction {
            for table in ["moz_historyvisits", "moz_historyvisits_extra", "moz_inputhistory",
                          "moz_places_metadata", "moz_places_metadata_search_queries"] {
                if try db.tableExists(table) {
                    try db.execute("DELETE FROM \(table)")
                }
            }
            // Pages that aren't bookmarked or keyworded (foreign_count = 0) only exist because of history.
            let unreferenced = "SELECT id FROM moz_places WHERE foreign_count = 0"
            for table in ["moz_annos", "moz_places_extra"] {
                if try db.tableExists(table), try db.columns(of: table).contains("place_id") {
                    try db.execute("DELETE FROM \(table) WHERE place_id IN (\(unreferenced))")
                }
            }
            try db.execute("DELETE FROM moz_places WHERE foreign_count = 0")
            try db.execute("UPDATE moz_places SET visit_count = 0, last_visit_date = NULL, frecency = 0")
            try removeUnusedOrigins(in: db)
        }
    }

    private func removeUnusedOrigins(in db: SQLiteDatabase) throws {
        if try db.tableExists("moz_origins") {
            try db.execute("DELETE FROM moz_origins WHERE id NOT IN (SELECT origin_id FROM moz_places WHERE origin_id IS NOT NULL)")
        }
    }

    /// Pages with at least one visit. Bookmarked pages that were never visited aren't history.
    private func forEachPage(in db: SQLiteDatabase, profile: BrowserProfile, _ body: (Int64, HistoryEntry) throws -> Void) throws {
        let sql = "SELECT id, url, title, visit_count, last_visit_date FROM moz_places WHERE id IN (SELECT place_id FROM moz_historyvisits)"
        try db.forEachRow(sql) { row in
            let lastVisit = row.isNull(4) ? nil : Date(timeIntervalSince1970: Double(row.int64(4)) / 1_000_000)
            let page = HistoryEntry(browserID: browser.id, profileID: profile.id, rowID: row.int64(0), url: row.string(1),
                                    title: row.string(2), visitCount: Int(row.int64(3)), lastVisit: lastVisit)
            try body(row.int64(0), page)
        }
    }

    /// Every folder in the browser's Profiles cache folder, including those of profiles that no longer exist.
    func cacheDirectories(for profiles: [BrowserProfile]) -> [URL] {
        browser.cacheDirectories.flatMap { FileTools.subdirectories(of: $0.appending(path: "Profiles", directoryHint: .isDirectory)) }
    }

    func cache(for profiles: [BrowserProfile]) -> [CacheEntry] {
        let roots = cacheDirectories(for: profiles)
        let stores = roots.map { $0.appending(path: "cache2", directoryHint: .isDirectory) }.filter(FileTools.exists)
        var entries: [CacheEntry] = []
        for store in stores {
            let profileID = owner(of: store, among: profiles)
            entries += CacheFormats.firefoxRecords(in: store.appending(path: "entries")).map {
                CacheEntry(record: $0, browserID: browser.id, profileID: profileID, storeIndex: store.appending(path: "index"))
            }
        }
        return entries + looseCacheEntries(in: roots, outside: stores) { owner(of: $0, among: profiles) }
    }

    /// A profile's cache folder is named like its profile folder. Others belong to profiles that no longer exist.
    private func owner(of url: URL, among profiles: [BrowserProfile]) -> String {
        profiles.first { url.pathComponents.contains($0.directory.lastPathComponent) }?.id ?? ""
    }

    private func forEachCookie(in db: SQLiteDatabase, profile: BrowserProfile,
                               _ body: (Int64, BrowserCookie) throws -> Void) throws {
        let sql = "SELECT id, host, name, path, expiry, isSecure, isHttpOnly, originAttributes FROM moz_cookies"
        try db.forEachRow(sql) { row in
            let cookie = BrowserCookie(browserID: browser.id, profileID: profile.id, domain: row.string(1),
                                       name: row.string(2), path: row.string(3),
                                       expires: Self.date(fromExpiry: row.int64(4)),
                                       isSecure: row.int64(5) != 0, isHTTPOnly: row.int64(6) != 0,
                                       partition: row.string(7))
            try body(row.int64(0), cookie)
        }
    }

    /// Older versions store `expiry` in seconds, newer ones in milliseconds.
    private static func date(fromExpiry value: Int64) -> Date? {
        guard value > 0 else { return nil }
        let seconds = value > 100_000_000_000 ? Double(value) / 1000 : Double(value)
        return Date(timeIntervalSince1970: seconds)
    }

    /// Section names paired with their key/value pairs, in file order.
    private static func parseINI(_ text: String) -> [(String, [String: String])] {
        var sections: [(String, [String: String])] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                sections.append((String(line.dropFirst().dropLast()), [:]))
            } else if let equals = line.firstIndex(of: "="), !sections.isEmpty, !line.hasPrefix(";"), !line.hasPrefix("#") {
                let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
                sections[sections.count - 1].1[key] = value
            }
        }
        return sections
    }
}
