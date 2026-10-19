import Foundation

/// A cookie stored by one browser profile. Its value isn't part of it: a value is read only when the user copies it.
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

struct CookieValueError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}

enum Domain {
    private static let publicSuffixes = PublicSuffixList(
        contentsOf: Bundle.main.url(forResource: "public_suffix_list", withExtension: "dat"))

    /// "https://www.Example.com/page" gives "www.example.com"; URLs without a host, such as file URLs, give "".
    static func host(ofURL url: String) -> String {
        URL(string: url)?.host(percentEncoded: false)?.lowercased() ?? ""
    }

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

    /// The registrable domain: the public suffix plus one label, e.g. "www.bbc.co.uk" gives "bbc.co.uk" and
    /// "x.alice.github.io" gives "alice.github.io". A host that is itself a public suffix, such as "github.io", stays
    /// as it is.
    static func site(for host: String) -> String {
        let labels = host.split(separator: ".")
        guard labels.count > 2, !isIPAddress(host) else { return host }
        // "a.b.c" gives "a.b.c", "b.c" and "c".
        let suffixes = labels.map { host[$0.startIndex...] }
        let publicSuffix = publicSuffixes.index(in: suffixes)
        return publicSuffix == 0 ? host : String(suffixes[publicSuffix - 1])
    }

    static func isIPAddress(_ host: String) -> Bool {
        host.contains(":") || host.allSatisfy { $0.isNumber || $0 == "." }
    }
}

/// The rules of the Public Suffix List (https://publicsuffix.org), bundled as `public_suffix_list.dat`. Like browsers,
/// it uses the private section too, so "alice.github.io" and "bob.github.io" are separate sites.
private struct PublicSuffixList: Sendable {
    // Substrings, so a host's suffixes can be looked up without copying them.
    private var rules: Set<Substring> = []
    /// "ck" for the rule "*.ck".
    private var wildcardParents: Set<Substring> = []
    /// "www.ck" for the rule "!www.ck".
    private var exceptions: Set<Substring> = []

    init(contentsOf url: URL?) {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        for line in text.split(whereSeparator: \.isNewline) {
            // Only a line's first word counts, and comments start with "//".
            guard let word = line.split(whereSeparator: \.isWhitespace).first, !word.hasPrefix("//") else { continue }
            let rule = word.lowercased()
            if rule.hasPrefix("!") {
                exceptions.formUnion(Self.spellings(of: rule.dropFirst()))
            } else if rule.hasPrefix("*.") {
                wildcardParents.formUnion(Self.spellings(of: rule.dropFirst(2)))
            } else {
                rules.formUnion(Self.spellings(of: rule[...]))
            }
        }
    }

    /// Which of a host's suffixes, ordered from the whole host to its top-level domain, is its public suffix.
    func index(in suffixes: [Substring]) -> Int {
        // An exception rule beats every other rule, and its first label isn't part of the public suffix.
        if let exception = suffixes.firstIndex(where: exceptions.contains) {
            return exception + 1
        }
        // Otherwise the longest matching rule wins. With no match, the top-level domain is the public suffix.
        return suffixes.indices.first { index in
            rules.contains(suffixes[index])
                || (index + 1 < suffixes.count && wildcardParents.contains(suffixes[index + 1]))
        } ?? suffixes.count - 1
    }

    /// Internationalized rules are listed in Unicode, but hosts usually arrive in punycode ("xn--…"), so both count.
    private static func spellings(of name: Substring) -> [Substring] {
        guard !name.allSatisfy(\.isASCII) else { return [name] }
        var components = URLComponents()
        components.host = String(name)
        return [name] + (components.encodedHost.map { [$0[...]] } ?? [])
    }
}

/// Domains whose data is never removed by automatic cleanups. An entry also covers its subdomains.
struct ExceptionList: Sendable {
    private let domains: [String]

    init(_ domains: [String]) {
        self.domains = domains.map(Domain.normalize).filter { !$0.isEmpty }
    }

    func covers(_ host: String) -> Bool {
        domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
