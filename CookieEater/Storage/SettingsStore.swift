import Foundation
import os

/// Persists settings, the activity log and folder bookmarks as JSON in ~/Library/Application Support/CookieEater.
enum SettingsStore {
    private static let logger = Logger(subsystem: "dev.mrsheep.CookieEater", category: "SettingsStore")

    private static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "CookieEater", directoryHint: .isDirectory)
    }

    private static var settingsURL: URL { directory.appending(path: "Settings.json") }
    private static var activityURL: URL { directory.appending(path: "Activity.json") }
    private static var folderBookmarksURL: URL { directory.appending(path: "FolderAccess.json") }

    static func loadSettings() -> AppSettings {
        load(from: settingsURL) ?? AppSettings()
    }

    static func save(_ settings: AppSettings) {
        save(settings, to: settingsURL)
    }

    static func loadActivity() -> [ActivityEntry] {
        load(from: activityURL) ?? []
    }

    static func save(_ activity: [ActivityEntry]) {
        save(activity, to: activityURL)
    }

    /// Security-scoped bookmarks, keyed by folder path.
    static func loadFolderBookmarks() -> [String: Data] {
        load(from: folderBookmarksURL) ?? [:]
    }

    static func save(folderBookmarks: [String: Data]) {
        save(folderBookmarks, to: folderBookmarksURL)
    }

    private static func load<Value: Decodable>(from url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(Value.self, from: data)
        } catch {
            logger.error("Couldn't read \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func save<Value: Encodable>(_ value: Value, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(value).write(to: url, options: .atomic)
        } catch {
            logger.error("Couldn't save \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
