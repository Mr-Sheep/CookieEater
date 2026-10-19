import Foundation

/// What automatic cleanups remove from one profile.
struct ProfileAutomation: Codable, Equatable, Sendable {
    static let nothing = ProfileAutomation(cookies: false, history: false, cache: false)

    var cookies = true
    var history = false
    var cache = false

    init() {}

    init(cookies: Bool, history: Bool, cache: Bool) {
        self.cookies = cookies
        self.history = history
        self.cache = cache
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ProfileAutomation()
        cookies = try container.decodeIfPresent(Bool.self, forKey: .cookies) ?? defaults.cookies
        history = try container.decodeIfPresent(Bool.self, forKey: .history) ?? defaults.history
        cache = try container.decodeIfPresent(Bool.self, forKey: .cache) ?? defaults.cache
    }

    var isActive: Bool { cookies || history || cache }

    subscript(kind: DataKind) -> Bool {
        get {
            switch kind {
            case .cookies: cookies
            case .history: history
            case .cache: cache
            }
        }
        set {
            switch kind {
            case .cookies: cookies = newValue
            case .history: history = newValue
            case .cache: cache = newValue
            }
        }
    }
}

/// What automatic cleanups remove from each of one browser's profiles.
struct BrowserAutomation: Codable, Equatable, Sendable {
    /// What is removed from profiles that have no options of their own, such as profiles added later.
    var defaults = ProfileAutomation()
    /// Keyed by `BrowserProfile.id`.
    var profiles: [String: ProfileAutomation] = [:]

    private enum LegacyCodingKeys: String, CodingKey {
        case skippedProfiles
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Before each profile had its own options, the browser's were kept at the top level, and profiles could only
        // be left alone.
        defaults = try container.decodeIfPresent(ProfileAutomation.self, forKey: .defaults) ?? ProfileAutomation(from: decoder)
        profiles = try container.decodeIfPresent([String: ProfileAutomation].self, forKey: .profiles) ?? [:]
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        for profileID in try legacy.decodeIfPresent(Set<String>.self, forKey: .skippedProfiles) ?? [] {
            profiles[profileID] = .nothing
        }
    }

    subscript(profile: BrowserProfile) -> ProfileAutomation {
        profiles[profile.id] ?? defaults
    }

    /// Turns this kind of data on or off in one profile, or in every profile, including ones added later, when
    /// `profileID` is nil.
    mutating func set(_ kind: DataKind, _ isOn: Bool, inProfile profileID: String?) {
        if let profileID {
            profiles[profileID, default: defaults][kind] = isOn
        } else {
            defaults[kind] = isOn
            for id in profiles.keys {
                profiles[id]?[kind] = isOn
            }
        }
    }
}

struct CleanupSchedule: Codable, Equatable, Sendable {
    enum Frequency: String, Codable, CaseIterable, Sendable {
        case daily
        case interval
    }

    var isEnabled = false
    var frequency = Frequency.daily
    var hour = 18
    var minute = 0
    var intervalHours = 4
    /// When the schedule was last edited. Runs are counted from here so editing it never fires immediately.
    var anchor = Date()

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CleanupSchedule()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        frequency = try container.decodeIfPresent(Frequency.self, forKey: .frequency) ?? defaults.frequency
        hour = try container.decodeIfPresent(Int.self, forKey: .hour) ?? defaults.hour
        minute = try container.decodeIfPresent(Int.self, forKey: .minute) ?? defaults.minute
        intervalHours = try container.decodeIfPresent(Int.self, forKey: .intervalHours) ?? defaults.intervalHours
        anchor = try container.decodeIfPresent(Date.self, forKey: .anchor) ?? defaults.anchor
    }

    func nextRun(after date: Date, calendar: Calendar = .current) -> Date {
        switch frequency {
        case .daily:
            calendar.nextDate(after: date, matching: DateComponents(hour: hour, minute: minute),
                              matchingPolicy: .nextTime) ?? date.addingTimeInterval(24 * 3600)
        case .interval:
            date.addingTimeInterval(Double(max(intervalHours, 1)) * 3600)
        }
    }
}

/// How cookie and history databases are read. Only Chromium's are read the way the user chooses: Firefox and Safari
/// don't lock theirs, so they're always read in place.
enum DatabaseReading: String, Codable, Sendable {
    /// Read-only, where they are. Chromium locks its databases while it's open, so its cookies and history are read
    /// once it quits.
    case inPlace
    /// Through a copy in the temporary folder, deleted once it has been read. Works while any browser is open.
    case copy

    /// Whether this kind of data can't be read from this browser now.
    func isLocked(_ kind: DataKind, of browser: BrowserDefinition, isRunning: Bool) -> Bool {
        self == .inPlace && isRunning && browser.locksDatabasesWhileOpen && kind != .cache
    }
}

struct AppSettings: Codable, Equatable, Sendable {
    /// Sites whose cookies are kept. The name predates the history and cache lists.
    var exceptions: [String] = []
    var historyExceptions: [String] = []
    var cacheExceptions: [String] = []
    /// Keyed by `BrowserDefinition.id`.
    var automation: [String: BrowserAutomation] = [:]
    /// `BrowserDefinition.id`s of browsers CookieEater leaves alone: their data is neither read nor cleaned.
    var excludedBrowsers: Set<String> = []
    var cleanOnQuit = false
    var schedule = CleanupSchedule()
    var lastScheduledRun: Date?
    var showWindowAtLaunch = true
    /// Whether every browser's data is read again regularly while the window is open.
    var autoSyncsAllBrowsers = false
    /// `BrowserDefinition.id`s of browsers whose data is read again regularly while the window is open.
    var autoSyncedBrowsers: Set<String> = []
    /// How often auto sync reads the data again.
    var autoSyncSeconds = 15
    /// How Chromium browsers' databases are read.
    var chromiumReading = DatabaseReading.copy
    /// Whether cleanups and errors are added to the activity log.
    var logsActivity = true

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        exceptions = try container.decodeIfPresent([String].self, forKey: .exceptions) ?? defaults.exceptions
        historyExceptions = try container.decodeIfPresent([String].self, forKey: .historyExceptions) ?? defaults.historyExceptions
        cacheExceptions = try container.decodeIfPresent([String].self, forKey: .cacheExceptions) ?? defaults.cacheExceptions
        automation = try container.decodeIfPresent([String: BrowserAutomation].self, forKey: .automation) ?? defaults.automation
        excludedBrowsers = try container.decodeIfPresent(Set<String>.self, forKey: .excludedBrowsers) ?? defaults.excludedBrowsers
        cleanOnQuit = try container.decodeIfPresent(Bool.self, forKey: .cleanOnQuit) ?? defaults.cleanOnQuit
        schedule = try container.decodeIfPresent(CleanupSchedule.self, forKey: .schedule) ?? defaults.schedule
        lastScheduledRun = try container.decodeIfPresent(Date.self, forKey: .lastScheduledRun)
        showWindowAtLaunch = try container.decodeIfPresent(Bool.self, forKey: .showWindowAtLaunch) ?? defaults.showWindowAtLaunch
        autoSyncsAllBrowsers = try container.decodeIfPresent(Bool.self, forKey: .autoSyncsAllBrowsers) ?? defaults.autoSyncsAllBrowsers
        autoSyncedBrowsers = try container.decodeIfPresent(Set<String>.self, forKey: .autoSyncedBrowsers) ?? defaults.autoSyncedBrowsers
        autoSyncSeconds = try container.decodeIfPresent(Int.self, forKey: .autoSyncSeconds) ?? defaults.autoSyncSeconds
        chromiumReading = try container.decodeIfPresent(DatabaseReading.self, forKey: .chromiumReading) ?? defaults.chromiumReading
        logsActivity = try container.decodeIfPresent(Bool.self, forKey: .logsActivity) ?? defaults.logsActivity
    }

    func automation(for browserID: String) -> BrowserAutomation {
        automation[browserID] ?? BrowserAutomation()
    }

    /// The sites whose data of this kind is kept.
    subscript(exceptionsFor kind: DataKind) -> [String] {
        get {
            switch kind {
            case .cookies: exceptions
            case .history: historyExceptions
            case .cache: cacheExceptions
            }
        }
        set {
            switch kind {
            case .cookies: exceptions = newValue
            case .history: historyExceptions = newValue
            case .cache: cacheExceptions = newValue
            }
        }
    }
}

struct ActivityEntry: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var date = Date()
    var message: String
    var details: [String] = []
    var isError = false
}
