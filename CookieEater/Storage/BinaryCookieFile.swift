import Foundation

/// Reads and rewrites `Cookies.binarycookies`, the cookie store used by Safari and other WebKit apps.
///
/// File layout (big-endian): the "cook" magic, the page count, each page's size, the pages,
/// a checksum, then a trailer (a fixed footer followed by a binary plist of cookie settings).
/// Each page (little-endian) starts with the tag 0x00000100, a record count and the record offsets.
/// Each record stores its size, flags, the offsets of its strings (domain at 16, name at 20, path at 24, value at 28),
/// expiry and creation dates (seconds since 2001),
/// followed by the NUL-terminated domain, name, path and value strings.
struct BinaryCookieFile {
    struct Record {
        /// The record exactly as stored, so rewriting the file never alters the cookies that stay.
        let bytes: Data
        let domain: String
        let name: String
        let path: String
        let flags: UInt32
        let expires: Date

        var isSecure: Bool { flags & 0x1 != 0 }
        var isHTTPOnly: Bool { flags & 0x4 != 0 }

        /// Read from `bytes` only when asked for, so listing cookies never reads their values.
        func value() throws -> String {
            let record = [UInt8](bytes)
            return try BinaryCookieFile.string(record, at: Int(BinaryCookieFile.littleEndian(record, at: 28)))
        }
    }

    struct FormatError: LocalizedError {
        var errorDescription: String? { "The cookie file is damaged or in an unknown format." }
    }

    private static let recordHeaderSize = 56
    private static let footer: [UInt8] = [0x07, 0x17, 0x20, 0x05, 0x00, 0x00, 0x00, 0x4B]

    private(set) var pages: [[Record]]
    private let trailer: Data

    var records: [Record] { pages.flatMap { $0 } }

    init(data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, bytes[0..<4].elementsEqual("cook".utf8) else { throw FormatError() }
        let pageCount = Int(try Self.bigEndian(bytes, at: 4))
        var offset = 8 + 4 * pageCount
        guard bytes.count >= offset else { throw FormatError() }

        var pages: [[Record]] = []
        for index in 0..<pageCount {
            let size = Int(try Self.bigEndian(bytes, at: 8 + 4 * index))
            guard offset + size <= bytes.count else { throw FormatError() }
            pages.append(try Self.parsePage(Array(bytes[offset ..< offset + size])))
            offset += size
        }
        self.pages = pages
        // Skip the checksum (it is recomputed on write) and keep the rest verbatim.
        trailer = offset + 4 < bytes.count ? Data(bytes[(offset + 4)...]) : Data(Self.footer)
    }

    /// Removes matching records and returns how many were removed.
    mutating func removeAll(where shouldRemove: (Record) -> Bool) -> Int {
        let before = records.count
        pages = pages.map { $0.filter { !shouldRemove($0) } }.filter { !$0.isEmpty }
        return before - records.count
    }

    func serialized() -> Data {
        let pageData = pages.filter { !$0.isEmpty }.map(Self.serialize(page:))
        var data = Data("cook".utf8)
        data.appendBigEndian(UInt32(pageData.count))
        for page in pageData {
            data.appendBigEndian(UInt32(page.count))
        }
        var checksum: UInt32 = 0
        for page in pageData {
            data.append(page)
            for index in stride(from: page.startIndex, to: page.endIndex, by: 4) {
                checksum &+= UInt32(page[index])
            }
        }
        data.appendBigEndian(checksum)
        data.append(trailer)
        return data
    }

    private static func parsePage(_ page: [UInt8]) throws -> [Record] {
        let count = Int(try littleEndian(page, at: 4))
        return try (0..<count).map { index in
            let start = Int(try littleEndian(page, at: 8 + 4 * index))
            let size = Int(try littleEndian(page, at: start))
            guard size >= recordHeaderSize, start + size <= page.count else { throw FormatError() }
            let record = Array(page[start ..< start + size])
            return Record(bytes: Data(record),
                          domain: try string(record, at: Int(littleEndian(record, at: 16))),
                          name: try string(record, at: Int(littleEndian(record, at: 20))),
                          path: try string(record, at: Int(littleEndian(record, at: 24))),
                          flags: try littleEndian(record, at: 8),
                          expires: Date(timeIntervalSinceReferenceDate: try double(record, at: 40)))
        }
    }

    private static func serialize(page records: [Record]) -> Data {
        var page = Data()
        page.appendBigEndian(UInt32(0x0000_0100))
        page.appendLittleEndian(UInt32(records.count))
        var offset = 4 + 4 + 4 * records.count + 4
        for record in records {
            page.appendLittleEndian(UInt32(offset))
            offset += record.bytes.count
        }
        page.appendLittleEndian(UInt32(0))
        for record in records {
            page.append(record.bytes)
        }
        return page
    }

    private static func bigEndian(_ bytes: [UInt8], at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { throw FormatError() }
        return bytes[offset ..< offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func littleEndian(_ bytes: [UInt8], at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { throw FormatError() }
        return bytes[offset ..< offset + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func double(_ bytes: [UInt8], at offset: Int) throws -> Double {
        guard offset >= 0, offset + 8 <= bytes.count else { throw FormatError() }
        let bits = bytes[offset ..< offset + 8].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return Double(bitPattern: bits)
    }

    private static func string(_ bytes: [UInt8], at offset: Int) throws -> String {
        guard offset >= 0, offset < bytes.count else { throw FormatError() }
        let end = bytes[offset...].firstIndex(of: 0) ?? bytes.endIndex
        return String(decoding: bytes[offset ..< end], as: UTF8.self)
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
