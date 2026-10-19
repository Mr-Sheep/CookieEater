import Foundation

/// A cookie, history page or cache entry: something one browser profile keeps for a site.
protocol SiteData: Identifiable, Sendable where ID == String {
    var browserID: String { get }
    /// Empty for data shared by every profile of the browser.
    var profileID: String { get }
    /// The host exceptions are matched against.
    var host: String { get }
    /// The registrable domain items are grouped by. Empty when the item isn't tied to a site.
    var site: String { get }
    /// Bytes on disk. Only known for the cache.
    var size: Int64 { get }
}

extension SiteData {
    var size: Int64 { 0 }
}

extension BrowserCookie: SiteData {}

/// A page in one browser profile's history.
struct HistoryEntry: SiteData, Hashable {
    let browserID: String
    let profileID: String
    let url: String
    let title: String
    let visitCount: Int
    let lastVisit: Date?

    let host: String
    let site: String
    let id: String

    init(browserID: String, profileID: String, rowID: Int64, url: String, title: String, visitCount: Int, lastVisit: Date?) {
        self.browserID = browserID
        self.profileID = profileID
        self.url = url
        self.title = title
        self.visitCount = visitCount
        self.lastVisit = lastVisit
        host = Domain.host(ofURL: url)
        site = host.isEmpty ? "" : Domain.site(for: host)
        id = "\(profileID)\u{1F}\(rowID)"
    }
}

/// A cached resource, or a cache file or folder that isn't tied to a site.
struct CacheEntry: SiteData, Hashable {
    let browserID: String
    let profileID: String
    /// The resource's URL, or the location of a cache file or folder that isn't tied to a site.
    let name: String
    let size: Int64
    let lastUsed: Date?
    /// Deleted when the entry is removed.
    let files: [URL]
    /// The index of the cache store holding the entry. It goes stale once entries are removed, so it is deleted
    /// too, and the browser rebuilds it.
    let storeIndex: URL?

    /// The site the resource was loaded for, when the browser partitions its cache by site; otherwise the
    /// resource's own host.
    let host: String
    let site: String
    let id: String

    init(browserID: String, profileID: String, name: String, host: String, size: Int64, lastUsed: Date?,
         files: [URL], storeIndex: URL? = nil) {
        self.browserID = browserID
        self.profileID = profileID
        self.name = name
        self.size = size
        self.lastUsed = lastUsed
        self.files = files
        self.storeIndex = storeIndex
        self.host = host
        site = host.isEmpty ? "" : Domain.site(for: host)
        id = files.first?.path(percentEncoded: false) ?? name
    }
}
