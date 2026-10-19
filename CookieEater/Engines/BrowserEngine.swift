import Foundation

/// Reads and removes one browser family's data.
///
/// Reading works while the browser is open, except in place from a browser that locks its databases (see
/// `BrowserDefinition.locksDatabasesWhileOpen`). Removing must only happen while it is closed:
/// browsers keep this data in memory and would write it back.
protocol BrowserEngine: Sendable {
    var browser: BrowserDefinition { get }

    func profiles() -> [BrowserProfile]

    func cookies(in profile: BrowserProfile, reading: DatabaseReading) throws -> [BrowserCookie]

    /// Returns the number of cookies removed.
    func removeCookies(in profile: BrowserProfile, where shouldRemove: (BrowserCookie) -> Bool) throws -> Int

    /// Reads the values of `cookies`, decrypting them if needed, keyed by cookie ID.
    /// Cookies that no longer exist are left out.
    func cookieValues(of cookies: [BrowserCookie], in profile: BrowserProfile, reading: DatabaseReading) throws -> [String: String]

    /// The pages in the profile's history.
    func history(in profile: BrowserProfile, reading: DatabaseReading) throws -> [HistoryEntry]

    /// Returns the number of pages removed. Removing every page also deletes the files the browser derives
    /// from its history.
    func removeHistory(in profile: BrowserProfile, where shouldRemove: (HistoryEntry) -> Bool) throws -> Int

    /// Folders whose contents make up the cache of these profiles. Some may not exist.
    func cacheDirectories(for profiles: [BrowserProfile]) -> [URL]

    /// Everything in `cacheDirectories(for:)`: one entry per cached resource where the cache format can be read,
    /// plus entries for the remaining files and folders, which aren't tied to a site.
    func cache(for profiles: [BrowserProfile]) -> [CacheEntry]
}

extension CacheEntry {
    init(record: CacheFormats.Record, browserID: String, profileID: String, storeIndex: URL?) {
        self.init(browserID: browserID, profileID: profileID, name: record.url,
                  host: record.partitionHost ?? Domain.host(ofURL: record.url),
                  size: record.files.reduce(0) { $0 + FileTools.allocatedSize(of: $1) },
                  lastUsed: FileTools.modificationDate(record.files[0]), files: record.files, storeIndex: storeIndex)
    }

    /// Cache files that aren't tied to a site, such as GPU caches.
    init(location: URL, files: [URL], browserID: String, profileID: String) {
        self.init(browserID: browserID, profileID: profileID,
                  name: (location.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath, host: "",
                  size: files.reduce(0) { $0 + FileTools.allocatedSize(of: $1) },
                  lastUsed: FileTools.modificationDate(location), files: files)
    }
}

extension BrowserEngine {
    /// Entries for what `roots` hold outside the cache stores that are listed entry by entry.
    func looseCacheEntries(in roots: [URL], outside stores: [URL], owner: (URL) -> String) -> [CacheEntry] {
        FileTools.items(in: roots, outside: stores).map { item in
            CacheEntry(location: item.location, files: item.files, browserID: browser.id, profileID: owner(item.location))
        }
    }
}
