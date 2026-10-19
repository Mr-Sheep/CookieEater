import Foundation

/// What to remove from one browser.
struct CleanupRequest: Sendable {
    let browser: BrowserDefinition
    let profiles: [BrowserProfile]
    /// Which items to remove, for each kind of data to clean. Kinds that are missing are left alone.
    var removals: [DataKind: @Sendable (any SiteData) -> Bool] = [:]
}

struct CleanupReport: Sendable {
    let browserName: String
    var cookiesRemoved = 0
    var historyItemsRemoved = 0
    var cacheBytesFreed: Int64 = 0
    var errors: [String] = []

    var summary: String {
        var parts: [String] = []
        if cookiesRemoved > 0 {
            parts.append(cookiesRemoved == 1 ? "1 cookie" : "\(cookiesRemoved.formatted()) cookies")
        }
        if historyItemsRemoved > 0 {
            parts.append(historyItemsRemoved == 1 ? "1 history item" : "\(historyItemsRemoved.formatted()) history items")
        }
        if cacheBytesFreed > 0 {
            parts.append("\(cacheBytesFreed.formatted(.byteCount(style: .file))) of cache")
        }
        return parts.isEmpty ? "nothing to remove" : "removed " + parts.formatted(.list(type: .and))
    }
}

/// Runs removals one at a time, so two cleanups never edit the same files at once.
actor CleanupWorker {
    func perform(_ request: CleanupRequest) -> CleanupReport {
        let engine = request.browser.makeEngine()
        var report = CleanupReport(browserName: request.browser.name)

        func attempt(_ what: String, profile: BrowserProfile? = nil, _ work: () throws -> Void) {
            do {
                try work()
            } catch {
                let scope = profile.map { " (\($0.name))" } ?? ""
                report.errors.append("\(what)\(scope): \(error.localizedDescription)")
            }
        }

        if let shouldRemove = request.removals[.cookies] {
            for profile in request.profiles where profile.cookiesFile != nil {
                attempt("Cookies", profile: profile) {
                    report.cookiesRemoved += try engine.removeCookies(in: profile) { shouldRemove($0) }
                }
            }
        }
        if let shouldRemove = request.removals[.history] {
            for profile in request.profiles where profile.historyFile != nil {
                attempt("History", profile: profile) {
                    report.historyItemsRemoved += try engine.removeHistory(in: profile) { shouldRemove($0) }
                }
            }
        }
        if let shouldRemove = request.removals[.cache] {
            attempt("Cache") {
                report.cacheBytesFreed += try removeCache(of: engine, profiles: request.profiles, where: shouldRemove)
            }
        }
        return report
    }

    /// Removing every entry empties the cache folders, including files that couldn't be listed.
    private func removeCache(of engine: any BrowserEngine, profiles: [BrowserProfile],
                             where shouldRemove: (any SiteData) -> Bool) throws -> Int64 {
        let entries = engine.cache(for: profiles)
        let removed = entries.filter { shouldRemove($0) }
        var freed: Int64 = 0
        var firstError: Error?
        if removed.count == entries.count {
            for directory in engine.cacheDirectories(for: profiles) where FileTools.exists(directory) {
                do {
                    freed += try FileTools.removeContents(of: directory)
                } catch {
                    firstError = firstError ?? error
                }
            }
        } else {
            for entry in removed {
                do {
                    for file in entry.files {
                        try FileTools.removeItemIfPresent(file)
                    }
                    freed += entry.size
                } catch {
                    firstError = firstError ?? error
                }
            }
            for index in Set(removed.compactMap(\.storeIndex)) {
                try? FileTools.removeItemIfPresent(index)
            }
        }
        if let firstError { throw firstError }
        return freed
    }
}
