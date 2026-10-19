import Foundation

enum Permissions {
    static let fullDiskAccessSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// Safari's data folders are protected by macOS; listing ~/Library/Safari only works with Full Disk Access.
    static func hasFullDiskAccess() -> Bool {
        let probe = URL.homeDirectory.appending(path: "Library/Safari", directoryHint: .isDirectory)
        guard FileTools.exists(probe) else { return true }
        return (try? FileManager.default.contentsOfDirectory(atPath: probe.path(percentEncoded: false))) != nil
    }
}
