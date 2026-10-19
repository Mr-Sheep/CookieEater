import Foundation

enum FileTools {
    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    /// Whether macOS stops CookieEater from opening an existing folder, as it does with Safari's
    /// until the user allows them.
    static func isBlocked(_ folder: URL) -> Bool {
        guard exists(folder) else { return false }
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
            return false
        } catch {
            return (error as NSError).code == NSFileReadNoPermissionError
        }
    }

    /// Whether `item` is `folder` itself or somewhere inside it.
    static func isItem(_ item: URL, inside folder: URL) -> Bool {
        item.standardizedFileURL.pathComponents.starts(with: folder.standardizedFileURL.pathComponents)
    }

    static func isNonEmptyFile(_ url: URL) -> Bool {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return size > 0
    }

    static func children(of directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }

    static func fileSize(_ url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Folders named `name` inside `roots`, at most `depth` levels down. Their contents aren't searched.
    static func folders(named name: String, in roots: [URL], depth: Int) -> [URL] {
        var found: [URL] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
                continue
            }
            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                if url.lastPathComponent == name {
                    found.append(url)
                    enumerator.skipDescendants()
                } else if enumerator.level >= depth {
                    enumerator.skipDescendants()
                }
            }
        }
        return found
    }

    /// What `roots` hold outside the folders in `stores`. A root without a store counts as a whole (its contents
    /// are listed, so the folder itself is kept); otherwise each of its items outside the stores counts separately.
    static func items(in roots: [URL], outside stores: [URL]) -> [(location: URL, files: [URL])] {
        func isInStore(_ url: URL) -> Bool { stores.contains { isItem(url, inside: $0) } }
        func holdsStore(_ url: URL) -> Bool { stores.contains { isItem($0, inside: url) } }
        var items: [(location: URL, files: [URL])] = []
        func visit(_ url: URL) {
            guard !isInStore(url) else { return }
            if holdsStore(url) {
                children(of: url).forEach(visit)
            } else {
                items.append((url, [url]))
            }
        }
        for root in roots where !isInStore(root) {
            if holdsStore(root) {
                children(of: root).forEach(visit)
            } else {
                let contents = children(of: root)
                if !contents.isEmpty {
                    items.append((root, contents))
                }
            }
        }
        return items
    }

    static func subdirectories(of directory: URL) -> [URL] {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    }

    /// The first file with the given extension inside `directory`, searching a few levels deep.
    static func firstFile(in directory: URL, withExtension pathExtension: String) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }
        for case let url as URL in enumerator {
            if enumerator.level > 3 { enumerator.skipDescendants() }
            if url.pathExtension == pathExtension { return url }
        }
        return nil
    }

    /// Disk space used by a file or folder, including everything inside it.
    static func allocatedSize(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .totalFileAllocatedSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        guard values.isDirectory == true else { return Int64(values.totalFileAllocatedSize ?? 0) }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else {
            return 0
        }
        var total: Int64 = 0
        for case let child as URL in enumerator {
            total += Int64((try? child.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Deletes everything inside `directory`, keeping the folder itself. Returns the bytes freed.
    static func removeContents(of directory: URL) throws -> Int64 {
        let children = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var freed: Int64 = 0
        var firstError: Error?
        for child in children {
            let size = allocatedSize(of: child)
            do {
                try FileManager.default.removeItem(at: child)
                freed += size
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
        return freed
    }

    static func removeItemIfPresent(_ url: URL) throws {
        guard exists(url) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Snapshot folders are named this followed by a UUID.
    private static let snapshotPrefix = "CookieEater-"

    /// Reads an SQLite database through a private copy, so a running browser's locks don't get in the way
    /// and the original is never touched.
    static func readSQLiteSnapshot<T>(_ url: URL, _ body: (SQLiteDatabase) throws -> T) throws -> T {
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory.appending(path: snapshotPrefix + UUID().uuidString, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: folder) }

        let copy = folder.appending(path: url.lastPathComponent)
        try fileManager.copyItem(at: url, to: copy)
        // Committed changes may still live in the write-ahead log or a hot journal.
        for suffix in ["-wal", "-journal"] {
            let sidecar = URL(filePath: url.path(percentEncoded: false) + suffix)
            if exists(sidecar) {
                try? fileManager.copyItem(at: sidecar, to: URL(filePath: copy.path(percentEncoded: false) + suffix))
            }
        }
        return try body(SQLiteDatabase(url: copy))
    }

    /// Deletes the snapshots left behind when CookieEater quit in the middle of a read, e.g. after a crash.
    static func removeLeftoverSnapshots() {
        for folder in children(of: FileManager.default.temporaryDirectory) {
            let name = folder.lastPathComponent
            guard name.hasPrefix(snapshotPrefix), UUID(uuidString: String(name.dropFirst(snapshotPrefix.count))) != nil else {
                continue
            }
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
