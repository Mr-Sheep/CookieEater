import AppKit

/// Opens the folders macOS protects, such as Safari's, without Full Disk Access.
///
/// The user allows each folder by choosing it in an open panel. macOS remembers that choice for CookieEater,
/// and CookieEater also keeps a security-scoped bookmark of the folder, which it renews at every launch.
@MainActor
final class FolderAccess {
    /// Keyed by folder path.
    private var bookmarks: [String: Data]

    init() {
        bookmarks = SettingsStore.loadFolderBookmarks()
        for (path, bookmark) in bookmarks {
            renew(path: path, bookmark: bookmark)
        }
    }

    /// Shows an open panel on `folder` and returns whether CookieEater can open it afterwards.
    func requestAccess(to folder: URL, message: String) -> Bool {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.directoryURL = folder
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.message = message
        panel.prompt = "Allow"
        guard panel.runModal() == .OK, let chosen = panel.url else { return false }

        // Choosing a parent folder covers this one too; choosing a folder inside it doesn't.
        guard folder.standardizedFileURL.pathComponents.starts(with: chosen.standardizedFileURL.pathComponents) else {
            let alert = NSAlert()
            alert.messageText = "Choose the folder the window opened in"
            alert.informativeText = "CookieEater needs “\((folder.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath)”. Click Allow without opening another folder."
            alert.runModal()
            return false
        }
        if let bookmark = try? chosen.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            bookmarks[chosen.path(percentEncoded: false)] = bookmark
            SettingsStore.save(folderBookmarks: bookmarks)
        }
        return !FileTools.isBlocked(folder)
    }

    private func renew(path: String, bookmark: Data) {
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                                 relativeTo: nil, bookmarkDataIsStale: &isStale),
              url.startAccessingSecurityScopedResource() else {
            bookmarks[path] = nil
            SettingsStore.save(folderBookmarks: bookmarks)
            return
        }
        // Access is kept until CookieEater quits, so it is never stopped.
        if isStale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            bookmarks[path] = fresh
            SettingsStore.save(folderBookmarks: bookmarks)
        }
    }
}
