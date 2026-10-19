import Foundation

/// Read-only snapshots of the installed browsers and their data.
struct BrowserScan: Sendable {
    var browsers: [InstalledBrowser] = []
    var cookies: [BrowserCookie] = []
    var problems: [String] = []

    /// Lists the installed browsers and reads their cookies. Excluded browsers are listed, but their cookies are
    /// not read.
    static func perform(excluding excluded: Set<String> = []) -> BrowserScan {
        var scan = BrowserScan()
        for definition in BrowserDefinition.all where definition.isBuiltIn || FileTools.exists(definition.dataDirectory) {
            let engine = definition.makeEngine()
            let profiles = engine.profiles()
            guard !profiles.isEmpty else { continue }
            let browser = InstalledBrowser(definition: definition, profiles: profiles)
            scan.browsers.append(browser)
            guard !excluded.contains(definition.id), isOpen(.cookies, of: browser) else { continue }
            for profile in profiles {
                do {
                    scan.cookies += try engine.cookies(in: profile)
                } catch {
                    scan.problems.append("\(label(browser, profile)): \(error.localizedDescription)")
                }
            }
        }
        return scan
    }

    static func history(of browsers: [InstalledBrowser]) -> (pages: [HistoryEntry], problems: [String]) {
        var pages: [HistoryEntry] = []
        var problems: [String] = []
        for browser in browsers where isOpen(.history, of: browser) {
            let engine = browser.definition.makeEngine()
            for profile in browser.profiles where profile.historyFile != nil {
                do {
                    pages += try engine.history(in: profile)
                } catch {
                    problems.append("\(label(browser, profile)): \(error.localizedDescription)")
                }
            }
        }
        return (pages, problems)
    }

    static func cache(of browsers: [InstalledBrowser]) -> [CacheEntry] {
        browsers.filter { isOpen(.cache, of: $0) }.flatMap { $0.definition.makeEngine().cache(for: $0.profiles) }
    }

    /// Whether the user has allowed CookieEater to open this data, where macOS protects it.
    private static func isOpen(_ kind: DataKind, of browser: InstalledBrowser) -> Bool {
        !browser.definition.protectedFolders(for: kind).contains(where: FileTools.isBlocked)
    }

    private static func label(_ browser: InstalledBrowser, _ profile: BrowserProfile) -> String {
        browser.profiles.count > 1 ? "\(browser.name) (\(profile.name))" : browser.name
    }
}
