import Foundation

/// How cookies are written to the clipboard.
enum CookieCopyFormat: Sendable {
    /// The value alone.
    case value
    /// "name=value".
    case pair
    /// "Cookie: a=1; b=2", for `curl -H` or `wget --header`.
    case header
    /// An array of cookies with their attributes, in the format cookie editor extensions import and export.
    case json

    /// `values` are keyed by cookie ID. Cookies without a value are left out.
    func text(for cookies: [BrowserCookie], values: [String: String]) -> String {
        let found = cookies.compactMap { cookie in values[cookie.id].map { (cookie: cookie, value: $0) } }
        switch self {
        case .value:
            return found.map(\.value).joined(separator: "\n")
        case .pair:
            return found.map { "\($0.cookie.name)=\($0.value)" }.joined(separator: "\n")
        case .header:
            return "Cookie: " + found.map { "\($0.cookie.name)=\($0.value)" }.joined(separator: "; ")
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let exported = found.map { ExportedCookie($0.cookie, value: $0.value) }
            return (try? encoder.encode(exported)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        }
    }
}

private struct ExportedCookie: Encodable {
    let domain: String
    /// Seconds since 1970. Left out for session cookies.
    let expirationDate: Int64?
    /// Set without a Domain attribute, so only sent to this exact host.
    let hostOnly: Bool
    let httpOnly: Bool
    let name: String
    let path: String
    let secure: Bool
    let session: Bool
    let value: String

    init(_ cookie: BrowserCookie, value: String) {
        domain = cookie.domain
        expirationDate = cookie.expires.map { Int64($0.timeIntervalSince1970.rounded()) }
        hostOnly = !cookie.domain.hasPrefix(".")
        httpOnly = cookie.isHTTPOnly
        name = cookie.name
        path = cookie.path
        secure = cookie.isSecure
        session = cookie.expires == nil
        self.value = value
    }
}
