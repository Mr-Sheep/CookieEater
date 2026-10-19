import Foundation

/// A read-only snapshot of every installed browser's profiles and cookies.
struct BrowserScan: Sendable {
    var browsers: [InstalledBrowser] = []
    var cookies: [BrowserCookie] = []
    var problems: [String] = []

    static func perform() -> BrowserScan {
        var scan = BrowserScan()
        for definition in BrowserDefinition.all where definition.isBuiltIn || FileTools.exists(definition.dataDirectory) {
            let engine = definition.makeEngine()
            let profiles = engine.profiles()
            guard !profiles.isEmpty else { continue }
            scan.browsers.append(InstalledBrowser(definition: definition, profiles: profiles))
            for profile in profiles {
                do {
                    scan.cookies += try engine.cookies(in: profile)
                } catch {
                    let label = profiles.count > 1 ? "\(definition.name) (\(profile.name))" : definition.name
                    scan.problems.append("\(label): \(error.localizedDescription)")
                }
            }
        }
        return scan
    }
}

/// History and cache sizes shown for each browser.
struct BrowserStats: Sendable {
    /// History pages, keyed by profile ID. Profiles whose history couldn't be read are missing.
    var historyItems: [String: Int] = [:]
    var cacheBytes: Int64 = 0

    static func collect(for browser: InstalledBrowser) -> BrowserStats {
        let engine = browser.definition.makeEngine()
        var stats = BrowserStats()
        for profile in browser.profiles where profile.historyFile != nil {
            stats.historyItems[profile.id] = try? engine.historyCount(in: profile)
        }
        stats.cacheBytes = engine.cacheDirectories(for: browser.profiles).reduce(0) { $0 + FileTools.allocatedSize(of: $1) }
        return stats
    }
}
