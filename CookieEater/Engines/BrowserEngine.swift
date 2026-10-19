import Foundation

/// Reads and removes one browser family's data.
///
/// Reading works while the browser is open. Removing must only happen while it is closed:
/// browsers keep this data in memory and would write it back.
protocol BrowserEngine: Sendable {
    var browser: BrowserDefinition { get }

    func profiles() -> [BrowserProfile]

    func cookies(in profile: BrowserProfile) throws -> [BrowserCookie]

    /// Returns the number of cookies removed.
    func removeCookies(in profile: BrowserProfile, where shouldRemove: (BrowserCookie) -> Bool) throws -> Int

    /// The number of pages in the profile's history.
    func historyCount(in profile: BrowserProfile) throws -> Int

    /// Returns the number of history pages removed.
    func clearHistory(in profile: BrowserProfile) throws -> Int

    /// Folders whose contents make up the browser's cache. Some may not exist.
    func cacheDirectories(for profiles: [BrowserProfile]) -> [URL]
}
