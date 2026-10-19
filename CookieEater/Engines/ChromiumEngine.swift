import Foundation

/// Chrome and browsers built on Chromium (Edge, Brave, Vivaldi, Opera, Arc, …).
///
/// Profiles are listed in the "Local State" JSON file. Each profile folder holds `Cookies` and
/// `History` SQLite databases; most of the cache lives under ~/Library/Caches.
struct ChromiumEngine: BrowserEngine {
    let browser: BrowserDefinition

    /// History tables, emptied in this order. Missing tables are skipped.
    private static let historyTables = [
        "visits", "visit_source", "urls", "keyword_search_terms", "segments", "segment_usage", "visited_links",
        "clusters_and_visits", "clusters", "cluster_keywords", "cluster_visit_duplicates",
        "content_annotations", "context_annotations",
    ]

    /// Files derived from history, which Chromium rebuilds on its own.
    private static let historyFiles = [
        "Visited Links", "Top Sites", "Top Sites-journal", "Shortcuts", "Shortcuts-journal",
        "Network Action Predictor", "Network Action Predictor-journal", "History Provider Cache",
    ]

    /// Databases derived from history that also hold entries for other pages, with the table listing pages by URL.
    private static let historyURLTables = [("Shortcuts", "omni_box_shortcuts"), ("Network Action Predictor", "network_action_predictor")]

    private static let profileCacheFolders = ["Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache"]
    private static let sharedCacheFolders = ["GrShaderCache", "ShaderCache", "GraphiteDawnCache", "GPUPersistentCache"]

    func profiles() -> [BrowserProfile] {
        let root = browser.dataDirectory
        var names = profileNames(in: root)
        if names.isEmpty {
            let folders = (try? FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))) ?? []
            for folder in folders where folder == "Default" || folder.hasPrefix("Profile ") {
                names[folder] = folder
            }
        }
        var profiles = names.compactMap { folder, name -> BrowserProfile? in
            let directory = root.appending(path: folder, directoryHint: .isDirectory)
            return FileTools.exists(directory) ? makeProfile(folder: folder, name: name, directory: directory) : nil
        }
        // Some builds keep their only profile directly in the data folder.
        if profiles.isEmpty, FileTools.exists(root.appending(path: "Cookies")) || FileTools.exists(root.appending(path: "History")) {
            profiles.append(makeProfile(folder: "Default", name: "Default", directory: root))
        }
        return profiles.sorted { lhs, rhs in
            let lhsIsDefault = lhs.directory.lastPathComponent == "Default"
            let rhsIsDefault = rhs.directory.lastPathComponent == "Default"
            if lhsIsDefault != rhsIsDefault { return lhsIsDefault }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
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
        var rowIDs: [Int64] = []
        try forEachCookie(in: db, profile: profile) { rowID, cookie in
            if shouldRemove(cookie) { rowIDs.append(rowID) }
        }
        guard !rowIDs.isEmpty else { return 0 }
        try db.execute("PRAGMA secure_delete = ON")
        try db.transaction {
            try db.run("DELETE FROM cookies WHERE rowid = ?", binding: rowIDs)
        }
        return rowIDs.count
    }

    func cookieValues(of cookies: [BrowserCookie], in profile: BrowserProfile) throws -> [String: String] {
        guard let url = profile.cookiesFile else { return [:] }
        let wanted = Set(cookies.map(\.id))
        let stored = try FileTools.readSQLiteSnapshot(url) { db in
            var stored: [(cookie: BrowserCookie, value: String, encrypted: Data)] = []
            try forEachCookie(in: db, profile: profile) { rowID, cookie in
                guard wanted.contains(cookie.id) else { return }
                try db.forEachRow("SELECT value, encrypted_value FROM cookies WHERE rowid = ?", binding: rowID) { row in
                    stored.append((cookie, row.string(0), row.data(1)))
                }
            }
            return stored
        }
        // Values are stored in plain text only by old versions. The password is asked for once, when first needed.
        var password: Data?
        var values: [String: String] = [:]
        for (cookie, value, encrypted) in stored {
            guard value.isEmpty, !encrypted.isEmpty else {
                values[cookie.id] = value
                continue
            }
            let key = try password ?? safeStoragePassword()
            password = key
            values[cookie.id] = try ChromiumSafeStorage.decrypt(encrypted, password: key, domain: cookie.domain)
        }
        return values
    }

    private func safeStoragePassword() throws -> Data {
        guard let service = browser.safeStorageService else {
            throw CookieValueError("CookieEater doesn't know where \(browser.name) keeps its encryption password.")
        }
        return try ChromiumSafeStorage.password(service: service)
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
        var urls: [String] = []
        var total = 0
        try forEachPage(in: db, profile: profile) { id, page in
            total += 1
            if shouldRemove(page) {
                ids.append(id)
                urls.append(page.url)
            }
        }
        try db.execute("PRAGMA secure_delete = ON")
        if ids.count == total {
            try clearAllHistory(in: db, profile: profile)
            return total
        }
        guard !ids.isEmpty else { return 0 }

        try db.transaction {
            try db.execute("CREATE TEMP TABLE removed_urls (id INTEGER PRIMARY KEY)")
            try db.run("INSERT INTO removed_urls VALUES (?)", binding: ids)
            try db.execute("CREATE TEMP TABLE removed_visits AS SELECT id FROM visits WHERE url IN (SELECT id FROM removed_urls)")
            let visits = "SELECT id FROM removed_visits"
            for (table, column) in [("visit_source", "id"), ("content_annotations", "visit_id"), ("context_annotations", "visit_id"),
                                    ("clusters_and_visits", "visit_id"), ("cluster_visit_duplicates", "visit_id"), ("visits", "id")] {
                try db.deleteRows(from: table, where: column, in: visits)
            }
            let pages = "SELECT id FROM removed_urls"
            try db.deleteRows(from: "segment_usage", where: "segment_id", in: "SELECT id FROM segments WHERE url_id IN (\(pages))")
            for (table, column) in [("segments", "url_id"), ("keyword_search_terms", "url_id"), ("visited_links", "link_url_id"),
                                    ("urls", "id")] {
                try db.deleteRows(from: table, where: column, in: pages)
            }
        }
        // Chromium rebuilds these from what is left of the history.
        for name in ["Visited Links", "Top Sites", "Top Sites-journal", "History Provider Cache"] {
            try FileTools.removeItemIfPresent(profile.directory.appending(path: name))
        }
        for (file, table) in Self.historyURLTables {
            let derivedFile = profile.directory.appending(path: file)
            guard FileTools.exists(derivedFile) else { continue }
            let derived = try SQLiteDatabase(url: derivedFile)
            guard try derived.tableExists(table), try derived.columns(of: table).contains("url") else { continue }
            try derived.execute("PRAGMA secure_delete = ON")
            try derived.transaction {
                try derived.run("DELETE FROM \(table) WHERE url = ?", binding: urls)
            }
        }
        return ids.count
    }

    func cacheDirectories(for profiles: [BrowserProfile]) -> [URL] {
        let perProfile = profiles.flatMap { profile in
            Self.profileCacheFolders.map { profile.directory.appending(path: $0, directoryHint: .isDirectory) }
        }
        let shared = Self.sharedCacheFolders.map { browser.dataDirectory.appending(path: $0, directoryHint: .isDirectory) }
        return browser.cacheDirectories + perProfile + shared
    }

    func cache(for profiles: [BrowserProfile]) -> [CacheEntry] {
        let roots = cacheDirectories(for: profiles)
        // The HTTP cache is in "<profile>/Cache/Cache_Data", usually under ~/Library/Caches.
        let stores = FileTools.folders(named: "Cache_Data", in: roots, depth: 4)
        var entries: [CacheEntry] = []
        for store in stores {
            let profileID = owner(of: store, among: profiles)
            entries += CacheFormats.chromiumRecords(in: store).map {
                CacheEntry(record: $0, browserID: browser.id, profileID: profileID,
                           storeIndex: store.appending(path: "index-dir/the-real-index"))
            }
        }
        return entries + looseCacheEntries(in: roots, outside: stores) { owner(of: $0, among: profiles) }
    }

    /// Per-profile caches sit in, or in a folder named like, the profile's folder. Others are shared.
    private func owner(of url: URL, among profiles: [BrowserProfile]) -> String {
        profiles.first { profile in
            FileTools.isItem(url, inside: profile.directory) || url.pathComponents.contains(profile.directory.lastPathComponent)
        }?.id ?? ""
    }

    private func clearAllHistory(in db: SQLiteDatabase, profile: BrowserProfile) throws {
        try db.transaction {
            for table in Self.historyTables {
                if try db.tableExists(table) {
                    try db.execute("DELETE FROM \(table)")
                }
            }
        }
        for name in Self.historyFiles {
            try FileTools.removeItemIfPresent(profile.directory.appending(path: name))
        }
    }

    private func forEachPage(in db: SQLiteDatabase, profile: BrowserProfile, _ body: (Int64, HistoryEntry) throws -> Void) throws {
        try db.forEachRow("SELECT id, url, title, visit_count, last_visit_time FROM urls") { row in
            let page = HistoryEntry(browserID: browser.id, profileID: profile.id, rowID: row.int64(0), url: row.string(1),
                                    title: row.string(2), visitCount: Int(row.int64(3)),
                                    lastVisit: Self.date(fromChromiumTime: row.int64(4)))
            try body(row.int64(0), page)
        }
    }

    private func makeProfile(folder: String, name: String, directory: URL) -> BrowserProfile {
        let cookies = ["Cookies", "Network/Cookies"].map { directory.appending(path: $0) }.first(where: FileTools.exists)
        let history = directory.appending(path: "History")
        return BrowserProfile(id: "\(browser.id)/\(folder)", browserID: browser.id, name: name, directory: directory,
                              cookiesFile: cookies, historyFile: FileTools.exists(history) ? history : nil)
    }

    /// Profile folder names mapped to display names, from "Local State".
    private func profileNames(in root: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: root.appending(path: "Local State")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = json["profile"] as? [String: Any],
              let infoCache = profile["info_cache"] as? [String: Any]
        else { return [:] }
        var names: [String: String] = [:]
        for (folder, info) in infoCache {
            names[folder] = ((info as? [String: Any])?["name"] as? String) ?? folder
        }
        return names
    }

    private func forEachCookie(in db: SQLiteDatabase, profile: BrowserProfile,
                               _ body: (Int64, BrowserCookie) throws -> Void) throws {
        // Partitioned cookies (CHIPS) are told apart by the top-level site they were set under.
        let partition = try db.columns(of: "cookies").contains("top_frame_site_key") ? "top_frame_site_key" : "''"
        let sql = "SELECT rowid, host_key, name, path, expires_utc, is_secure, is_httponly, \(partition) FROM cookies"
        try db.forEachRow(sql) { row in
            let cookie = BrowserCookie(browserID: browser.id, profileID: profile.id, domain: row.string(1),
                                       name: row.string(2), path: row.string(3),
                                       expires: Self.date(fromChromiumTime: row.int64(4)),
                                       isSecure: row.int64(5) != 0, isHTTPOnly: row.int64(6) != 0,
                                       partition: row.string(7))
            try body(row.int64(0), cookie)
        }
    }

    /// Chromium stores microseconds since 1601-01-01 UTC; 0 marks a session cookie or a page never visited.
    private static func date(fromChromiumTime value: Int64) -> Date? {
        guard value > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(value) / 1_000_000 - 11_644_473_600)
    }
}
