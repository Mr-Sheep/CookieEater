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

    func historyCount(in profile: BrowserProfile) throws -> Int {
        guard let url = profile.historyFile else { return 0 }
        return try FileTools.readSQLiteSnapshot(url) { try $0.scalarInt("SELECT count(*) FROM urls") }
    }

    func clearHistory(in profile: BrowserProfile) throws -> Int {
        guard let url = profile.historyFile else { return 0 }
        let db = try SQLiteDatabase(url: url)
        let removed = try db.scalarInt("SELECT count(*) FROM urls")
        try db.execute("PRAGMA secure_delete = ON")
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
        return removed
    }

    func cacheDirectories(for profiles: [BrowserProfile]) -> [URL] {
        let perProfile = profiles.flatMap { profile in
            Self.profileCacheFolders.map { profile.directory.appending(path: $0, directoryHint: .isDirectory) }
        }
        let shared = Self.sharedCacheFolders.map { browser.dataDirectory.appending(path: $0, directoryHint: .isDirectory) }
        return browser.cacheDirectories + perProfile + shared
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

    /// Chromium stores microseconds since 1601-01-01 UTC; 0 marks a session cookie.
    private static func date(fromChromiumTime value: Int64) -> Date? {
        guard value > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(value) / 1_000_000 - 11_644_473_600)
    }
}
