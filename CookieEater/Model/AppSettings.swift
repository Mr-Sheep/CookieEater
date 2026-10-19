import Foundation

/// What automatic cleanups remove from one browser.
struct BrowserAutomation: Codable, Equatable, Sendable {
    var cookies = true
    var history = false
    var cache = false
    /// `BrowserProfile.id`s of profiles that are left alone. Profiles added later are cleaned.
    var skippedProfiles: Set<String> = []

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = BrowserAutomation()
        cookies = try container.decodeIfPresent(Bool.self, forKey: .cookies) ?? defaults.cookies
        history = try container.decodeIfPresent(Bool.self, forKey: .history) ?? defaults.history
        cache = try container.decodeIfPresent(Bool.self, forKey: .cache) ?? defaults.cache
        skippedProfiles = try container.decodeIfPresent(Set<String>.self, forKey: .skippedProfiles) ?? defaults.skippedProfiles
    }

    var isActive: Bool { cookies || history || cache }

    func cleans(_ profile: BrowserProfile) -> Bool {
        !skippedProfiles.contains(profile.id)
    }

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
