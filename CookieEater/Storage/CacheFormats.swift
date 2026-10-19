import Foundation

/// Reads the keys of cached resources, so a browser's cache can be listed by site. Cached contents are never read.
enum CacheFormats {
    /// One cached resource.
    struct Record {
        let url: String
        /// The host of the top-level site the resource was loaded for, when the cache is partitioned by site.
        let partitionHost: String?
        /// The record's files, main file first.
        let files: [URL]
    }

    // MARK: Chromium

    private static let chromiumMagicNumber: UInt64 = 0xfcfb_6d1b_a772_5c30

    /// Chromium's "simple" cache keeps each entry in `<hash>_0`, with optional `<hash>_1` and `<hash>_s` files.
    /// `<hash>_0` starts with a 24-byte header (magic number, version, key length, key hash), followed by the key.
    static func chromiumRecords(in store: URL) -> [Record] {
        FileTools.children(of: store).filter { $0.lastPathComponent.hasSuffix("_0") }.compactMap { file in
            guard let header = read(file, at: 0, count: 24), header.count == 24,
                  header.integer(UInt64.self, at: 0, bigEndian: false) == chromiumMagicNumber else { return nil }
            let keyLength = Int(header.integer(UInt32.self, at: 12, bigEndian: false))
            guard keyLength > 0, keyLength < 65_536, let keyData = read(file, at: 24, count: keyLength),
                  let key = String(data: keyData, encoding: .utf8) else { return nil }
            let (url, partitionHost) = parseChromiumKey(key)
            let hash = String(file.lastPathComponent.dropLast(2))
            let siblings = ["_1", "_s"].map { file.deletingLastPathComponent().appending(path: hash + $0) }
            return Record(url: url, partitionHost: partitionHost, files: [file] + siblings.filter(FileTools.exists))
        }
    }

    /// A partitioned key looks like "1/0/_dk_https://site.com https://site.com https://cdn.com/file.js": the
    /// top-level site, the frame's site, then the resource. Older keys hold only the resource's URL.
    static func parseChromiumKey(_ key: String) -> (url: String, partitionHost: String?) {
        let parts = key.split(separator: " ").map { droppingMarkers(String($0)) }
        let partitionHost = parts.count >= 3 ? Domain.host(ofURL: parts[0]) : ""
        return (parts.last ?? key, partitionHost.isEmpty ? nil : partitionHost)
    }

    /// "1/0/_dk_https://a.com" gives "https://a.com".
    private static func droppingMarkers(_ token: String) -> String {
        guard let separator = token.range(of: "://") else { return token }
        var start = separator.lowerBound
        while start > token.startIndex {
            let previous = token.index(before: start)
            guard token[previous].isLetter || token[previous].isNumber || "+-.".contains(token[previous]) else { break }
            start = previous
        }
        return String(token[start...])
    }

    // MARK: Firefox

    /// Firefox's cache2 keeps each entry in one file. The key is in metadata at the end of the file: the last four
    /// bytes give the metadata's offset, where a hash of each 256 KiB chunk precedes a header and then the key.
    static func firefoxRecords(in entries: URL) -> [Record] {
        FileTools.children(of: entries).compactMap { file in
            guard let size = FileTools.fileSize(file), size >= 4,
                  let tail = read(file, at: size - 4, count: 4), tail.count == 4 else { return nil }
            let offset = Int(tail.integer(UInt32.self, at: 0, bigEndian: true))
            let chunkCount = (offset + 262_143) / 262_144
            let headerStart = offset + 4 + 2 * chunkCount
            guard headerStart + 32 <= size, let header = read(file, at: headerStart, count: 32), header.count == 32 else {
                return nil
            }
            // Version 1 headers have no flags field, so their key starts four bytes earlier.
            let version = header.integer(UInt32.self, at: 0, bigEndian: true)
            let keyLength = Int(header.integer(UInt32.self, at: 24, bigEndian: true))
            let keyStart = headerStart + (version >= 2 ? 32 : 28)
            guard keyLength > 0, keyStart + keyLength <= size, let keyData = read(file, at: keyStart, count: keyLength),
                  let key = String(data: keyData, encoding: .utf8) else { return nil }
            let (url, partitionHost) = parseFirefoxKey(key)
            return Record(url: url, partitionHost: partitionHost, files: [file])
        }
    }

    /// Keys look like "O^partitionKey=%28https%2Csite.com%29,a,:https://cdn.com/file.js": comma-separated tags
    /// (origin attributes follow "O^"), then a colon and the resource's URL.
    static func parseFirefoxKey(_ key: String) -> (url: String, partitionHost: String?) {
        let url = key.range(of: ",:").map { String(key[$0.upperBound...]) } ?? (key.hasPrefix(":") ? String(key.dropFirst()) : key)
        guard let start = key.range(of: "partitionKey=") else { return (url, nil) }
        // "(https,site.com)", with a port as a third field when it isn't the default.
        let value = key[start.upperBound...].prefix { $0 != "," && $0 != "&" }
        let fields = (value.removingPercentEncoding ?? String(value))
            .trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            .split(separator: ",")
        guard fields.count >= 2, fields[0] == "https" || fields[0] == "http" else { return (url, nil) }
        return (url, fields[1].lowercased())
    }

    // MARK: WebKit

    /// WebKit's network cache, which Safari uses, keeps each entry in `Records/<partition hash>/<type>/<hash>`, with
    /// the body in an optional `<hash>-blob` file next to it. A record starts with the cache version and three
    /// length-prefixed strings: the partition (the top-level site), the type and the URL.
    static func webKitRecords(in store: URL) -> [Record] {
        var records: [Record] = []
        for partition in FileTools.children(of: store.appending(path: "Records")) {
            for type in FileTools.children(of: partition) {
                for file in FileTools.children(of: type) where !file.lastPathComponent.hasSuffix("-blob") {
                    guard let data = read(file, at: 0, count: 8192) else { continue }
                    var reader = WebKitStringReader(data: data, offset: 4)
                    guard let partitionName = reader.next(), reader.next() != nil, let url = reader.next() else { continue }
                    let blob = type.appending(path: file.lastPathComponent + "-blob")
                    // Extensions get a UUID as their partition rather than a site.
                    records.append(Record(url: url, partitionHost: partitionName.contains(".") ? partitionName.lowercased() : nil,
                                          files: [file] + (FileTools.exists(blob) ? [blob] : [])))
                }
            }
        }
        return records
    }

    /// Reads strings the way WebKit's persistent encoder writes them: a 32-bit length, a flag for 8-bit
    /// characters, then Latin-1 or UTF-16 characters. A length of 0xFFFFFFFF is a null string.
    private struct WebKitStringReader {
        let data: Data
        var offset: Int

        mutating func next() -> String? {
            guard offset + 5 <= data.count else { return nil }
            let length = data.integer(UInt32.self, at: offset, bigEndian: false)
            offset += 4
            if length == .max { return "" }
            let is8Bit = data[data.startIndex + offset] != 0
            offset += 1
            let byteCount = Int(length) * (is8Bit ? 1 : 2)
            guard offset + byteCount <= data.count else { return nil }
            let bytes = data.subdata(in: data.startIndex + offset ..< data.startIndex + offset + byteCount)
            offset += byteCount
            return String(data: bytes, encoding: is8Bit ? .isoLatin1 : .utf16LittleEndian)
        }
    }

    // MARK: Reading

    private static func read(_ file: URL, at offset: Int, count: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: count)
        } catch {
            return nil
        }
    }
}

private extension Data {
    func integer<T: FixedWidthInteger>(_ type: T.Type, at offset: Int, bigEndian: Bool) -> T {
        let bytes = self[(startIndex + offset)..<(startIndex + offset + MemoryLayout<T>.size)]
        let ordered: [UInt8] = bigEndian ? Array(bytes) : Array(bytes.reversed())
        return ordered.reduce(0) { $0 << 8 | T($1) }
    }
}
