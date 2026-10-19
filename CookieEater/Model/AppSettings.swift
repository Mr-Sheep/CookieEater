import Foundation

/// What automatic cleanups remove from one browser.
struct BrowserAutomation: Codable, Equatable, Sendable {
    var cookies = true
    var history = false
    var cache = false

    var isActive: Bool { cookies || history || cache }
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
    var exceptions: [String] = []
    /// Keyed by `BrowserDefinition.id`.
    var automation: [String: BrowserAutomation] = [:]
    var cleanOnQuit = false
    var schedule = CleanupSchedule()
    var lastScheduledRun: Date?
    var showWindowAtLaunch = true

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        exceptions = try container.decodeIfPresent([String].self, forKey: .exceptions) ?? defaults.exceptions
        automation = try container.decodeIfPresent([String: BrowserAutomation].self, forKey: .automation) ?? defaults.automation
        cleanOnQuit = try container.decodeIfPresent(Bool.self, forKey: .cleanOnQuit) ?? defaults.cleanOnQuit
        schedule = try container.decodeIfPresent(CleanupSchedule.self, forKey: .schedule) ?? defaults.schedule
        lastScheduledRun = try container.decodeIfPresent(Date.self, forKey: .lastScheduledRun)
        showWindowAtLaunch = try container.decodeIfPresent(Bool.self, forKey: .showWindowAtLaunch) ?? defaults.showWindowAtLaunch
    }

    func automation(for browserID: String) -> BrowserAutomation {
        automation[browserID] ?? BrowserAutomation()
    }
}

struct ActivityEntry: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var date = Date()
    var message: String
    var details: [String] = []
    var isError = false
}
