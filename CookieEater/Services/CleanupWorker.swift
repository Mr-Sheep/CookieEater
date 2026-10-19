import Foundation

/// What to remove from one browser.
struct CleanupRequest: Sendable {
    let browser: BrowserDefinition
    let profiles: [BrowserProfile]
    var removeCookie: (@Sendable (BrowserCookie) -> Bool)?
    var clearHistory = false
    var clearCache = false
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

        if let removeCookie = request.removeCookie {
            for profile in request.profiles where profile.cookiesFile != nil {
                attempt("Cookies", profile: profile) {
                    report.cookiesRemoved += try engine.removeCookies(in: profile, where: removeCookie)
                }
            }
        }
        if request.clearHistory {
            for profile in request.profiles where profile.historyFile != nil {
                attempt("History", profile: profile) {
                    report.historyItemsRemoved += try engine.clearHistory(in: profile)
                }
            }
        }
        if request.clearCache {
            for directory in engine.cacheDirectories(for: request.profiles) where FileTools.exists(directory) {
                attempt("Cache") {
                    report.cacheBytesFreed += try FileTools.removeContents(of: directory)
                }
            }
        }
        return report
    }
}
