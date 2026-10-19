import Foundation

/// The engine a browser is built on, which decides how its data is stored on disk.
enum BrowserFamily: String, Sendable {
    case safari
    case chromium
    case firefox
}

/// The kinds of browsing data CookieEater removes, in the order they are shown.
enum DataKind: CaseIterable, Sendable {
    case history
    case cache
    case cookies

    var title: String {
        switch self {
        case .history: "History"
        case .cache: "Cache"
        case .cookies: "Cookies"
        }
    }

    /// "1 page", "3 cache entries", "12 cookies".
    func count(_ count: Int) -> String {
        switch self {
        case .history: count == 1 ? "1 page" : "\(count.formatted()) pages"
        case .cache: count == 1 ? "1 cache entry" : "\(count.formatted()) cache entries"
        case .cookies: count == 1 ? "1 cookie" : "\(count.formatted()) cookies"
        }
    }
}

/// A browser CookieEater knows how to clean, and where it keeps its data.
struct BrowserDefinition: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let family: BrowserFamily
    /// Every app that uses this data folder, e.g. Firefox, Firefox Developer Edition and Firefox Nightly.
    let bundleIDs: [String]
    /// The browser's data folder, relative to the home folder.
    let dataPath: String
    /// Folders holding the browser's cache, relative to the home folder.
    let cachePaths: [String]
    /// Safari only: the folder outside the app container that holds History.db.
    var historyPath: String? = nil
    /// Chromium only: the keychain item holding the password its cookie values are encrypted with.
    var safeStorageService: String? = nil
    /// Ships with macOS, so it is listed even before its data folder can be read.
    var isBuiltIn = false

    var dataDirectory: URL {
        URL.homeDirectory.appending(path: dataPath, directoryHint: .isDirectory)
    }

    var cacheDirectories: [URL] {
        cachePaths.map { URL.homeDirectory.appending(path: $0, directoryHint: .isDirectory) }
    }

    /// Chromium keeps its cookie and history databases locked while it's open, so other apps can only read them
    /// through a copy until it quits.
    var locksDatabasesWhileOpen: Bool { family == .chromium }

    /// How this browser's databases are read: the way the user chose for Chromium, otherwise in place.
    func databaseReading(chromium: DatabaseReading) -> DatabaseReading {
        locksDatabasesWhileOpen ? chromium : .inPlace
    }

    /// Folders macOS protects, which CookieEater can open only once the user allows each one.
    /// Only Safari's data is protected. Its data folder holds the cookies of every profile.
    func protectedFolders(for kind: DataKind) -> [URL] {
        guard family == .safari else { return [] }
        switch kind {
        case .cookies: return [dataDirectory]
        case .history: return historyPath.map { [URL.homeDirectory.appending(path: $0, directoryHint: .isDirectory)] } ?? []
        case .cache: return cacheDirectories
        }
    }

    func makeEngine() -> any BrowserEngine {
        switch family {
        case .safari: SafariEngine(browser: self)
        case .chromium: ChromiumEngine(browser: self)
        case .firefox: FirefoxEngine(browser: self)
        }
    }
}

extension BrowserDefinition {
    /// `keychainName` defaults to `name`, giving e.g. "Brave Safe Storage".
    private static func chromium(_ id: String, _ name: String, bundleID: String, folder: String, cacheFolder: String? = nil,
                                 keychainName: String? = nil) -> BrowserDefinition {
        BrowserDefinition(id: id, name: name, family: .chromium, bundleIDs: [bundleID],
                          dataPath: "Library/Application Support/\(folder)",
                          cachePaths: ["Library/Caches/\(cacheFolder ?? folder)"],
                          safeStorageService: "\(keychainName ?? name) Safe Storage")
    }

    private static func firefox(_ id: String, _ name: String, bundleIDs: [String], folder: String) -> BrowserDefinition {
        BrowserDefinition(id: id, name: name, family: .firefox, bundleIDs: bundleIDs,
                          dataPath: "Library/Application Support/\(folder)",
                          cachePaths: ["Library/Caches/\(folder)"])
    }

    /// Every supported browser. Browsers without data on this Mac are hidden.
    static let all: [BrowserDefinition] = [
        BrowserDefinition(id: "safari", name: "Safari", family: .safari, bundleIDs: ["com.apple.Safari"],
                          dataPath: "Library/Containers/com.apple.Safari/Data/Library",
                          cachePaths: ["Library/Caches/com.apple.Safari",
                                       "Library/Containers/com.apple.Safari/Data/Library/Caches/com.apple.Safari"],
                          historyPath: "Library/Safari",
                          isBuiltIn: true),
        BrowserDefinition(id: "safari-tp", name: "Safari Technology Preview", family: .safari,
                          bundleIDs: ["com.apple.SafariTechnologyPreview"],
                          dataPath: "Library/Containers/com.apple.SafariTechnologyPreview/Data/Library",
                          cachePaths: ["Library/Caches/com.apple.SafariTechnologyPreview",
                                       "Library/Containers/com.apple.SafariTechnologyPreview/Data/Library/Caches/com.apple.SafariTechnologyPreview"],
                          historyPath: "Library/SafariTechnologyPreview"),

        chromium("chrome", "Google Chrome", bundleID: "com.google.Chrome", folder: "Google/Chrome", keychainName: "Chrome"),
        chromium("chrome-beta", "Google Chrome Beta", bundleID: "com.google.Chrome.beta", folder: "Google/Chrome Beta",
                 keychainName: "Chrome"),
        chromium("chrome-dev", "Google Chrome Dev", bundleID: "com.google.Chrome.dev", folder: "Google/Chrome Dev",
                 keychainName: "Chrome"),
        chromium("chrome-canary", "Google Chrome Canary", bundleID: "com.google.Chrome.canary", folder: "Google/Chrome Canary",
                 keychainName: "Chrome"),
        chromium("chromium", "Chromium", bundleID: "org.chromium.Chromium", folder: "Chromium"),
        chromium("edge", "Microsoft Edge", bundleID: "com.microsoft.edgemac", folder: "Microsoft Edge"),
        chromium("brave", "Brave", bundleID: "com.brave.Browser", folder: "BraveSoftware/Brave-Browser"),
        chromium("vivaldi", "Vivaldi", bundleID: "com.vivaldi.Vivaldi", folder: "Vivaldi"),
        chromium("opera", "Opera", bundleID: "com.operasoftware.Opera", folder: "com.operasoftware.Opera"),
        chromium("arc", "Arc", bundleID: "company.thebrowser.Browser", folder: "Arc/User Data", cacheFolder: "Arc"),
        chromium("dia", "Dia", bundleID: "company.thebrowser.dia", folder: "Dia/User Data", cacheFolder: "Dia"),
        chromium("comet", "Comet", bundleID: "ai.perplexity.comet", folder: "Comet"),
        chromium("helium", "Helium", bundleID: "net.imput.helium", folder: "net.imput.helium"),

        firefox("firefox", "Firefox",
                bundleIDs: ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly"],
                folder: "Firefox"),
        firefox("zen", "Zen", bundleIDs: ["app.zen-browser.zen"], folder: "zen"),
        firefox("librewolf", "LibreWolf", bundleIDs: ["org.mozilla.librewolf", "io.gitlab.librewolf-community"], folder: "librewolf"),
        firefox("waterfox", "Waterfox", bundleIDs: ["net.waterfox.waterfox"], folder: "Waterfox"),
        firefox("floorp", "Floorp", bundleIDs: ["one.ablaze.floorp"], folder: "Floorp"),
        firefox("mullvad", "Mullvad Browser", bundleIDs: ["net.mullvad.mullvadbrowser"], folder: "MullvadBrowser"),
    ]
}

/// One profile of a browser. Browsers without profile support have a single "Default" profile.
struct BrowserProfile: Identifiable, Hashable, Sendable {
    let id: String
    let browserID: String
    let name: String
    let directory: URL
    var cookiesFile: URL?
    var historyFile: URL?
}

/// A supported browser that has data on this Mac.
struct InstalledBrowser: Identifiable, Hashable, Sendable {
    let definition: BrowserDefinition
    let profiles: [BrowserProfile]

    var id: String { definition.id }
    var name: String { definition.name }
}
