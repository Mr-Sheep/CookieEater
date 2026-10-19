import Foundation

/// A cookie stored by one browser profile. Cookie values are never read.
struct BrowserCookie: Identifiable, Hashable, Sendable {
    let browserID: String
    let profileID: String
    /// The domain as the browser stores it, e.g. ".example.com".
    let domain: String
    let name: String
    let path: String
    /// `nil` for session cookies.
    let expires: Date?
    let isSecure: Bool
    let isHTTPOnly: Bool
    /// Distinguishes otherwise identical cookies (partitioned cookies, Firefox containers).
    let partition: String

    /// `domain` without the leading dot, lowercased.
    let host: String
    /// The registrable domain the cookie belongs to, e.g. "example.co.uk".
    let site: String
    let id: String

    init(browserID: String, profileID: String, domain: String, name: String, path: String,
         expires: Date?, isSecure: Bool, isHTTPOnly: Bool, partition: String = "") {
        self.browserID = browserID
        self.profileID = profileID
        self.domain = domain
        self.name = name
        self.path = path
        self.expires = expires
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
        self.partition = partition
        host = Domain.host(fromCookieDomain: domain)
        site = Domain.site(for: host)
        id = [profileID, domain, name, path, partition].joined(separator: "\u{1F}")
    }
}

enum Domain {
    /// Second-level labels that act as public suffixes, so "example.co.uk" groups as one site.
    /// Deliberately short: a full public suffix list would be an external dependency.
    private static let multiLabelSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "ltd.uk", "plc.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au",
        "co.nz", "org.nz", "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp",
        "co.kr", "or.kr", "com.cn", "net.cn", "org.cn", "com.hk", "com.tw", "com.sg",
        "co.in", "com.br", "com.mx", "com.ar", "com.tr", "co.za", "co.il", "com.ua",
    ]

    static func host(fromCookieDomain domain: String) -> String {
        var host = domain.lowercased()
        while host.hasPrefix(".") { host.removeFirst() }
        return host
    }

    /// Turns user input such as "https://www.Example.com/path" into "www.example.com".
    static func normalize(_ input: String) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = text.range(of: "://") {
            text = String(text[scheme.upperBound...])
        }
        if let end = text.firstIndex(where: { "/?#".contains($0) }) {
            text = String(text[..<end])
        }
        if text.hasPrefix("*.") {
            text.removeFirst(2)
        }
        while text.hasPrefix(".") { text.removeFirst() }
        // Drop a port, but leave IPv6 addresses alone.
        if text.filter({ $0 == ":" }).count == 1, let colon = text.firstIndex(of: ":") {
            text = String(text[..<colon])
        }
        return text
    }

    static func site(for host: String) -> String {
        let labels = host.split(separator: ".")
        guard labels.count > 2, !isIPAddress(host) else { return host }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        return labels.suffix(multiLabelSuffixes.contains(lastTwo) ? 3 : 2).joined(separator: ".")
    }

    static func isIPAddress(_ host: String) -> Bool {
        host.contains(":") || host.allSatisfy { $0.isNumber || $0 == "." }
    }
}

/// Domains whose cookies are never removed by automatic cleanups. An entry also covers its subdomains.
struct ExceptionList: Sendable {
    private let domains: [String]

    init(_ domains: [String]) {
        self.domains = domains.map(Domain.normalize).filter { !$0.isEmpty }
    }

    func covers(_ host: String) -> Bool {
        domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
