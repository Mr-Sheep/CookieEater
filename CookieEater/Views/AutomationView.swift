import SwiftUI

struct AutomationView: View {
    private static let disclosureWidth: CGFloat = 12
    /// The choices for how often auto sync reads the data again, in seconds.
    private static let autoSyncIntervals = [5, 10, 15, 30, 60, 120, 300]

    @Environment(AppModel.self) private var model
    /// Browsers whose profiles are shown.
    @State private var expandedBrowserIDs: Set<String> = []

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("When a browser quits", isOn: $model.settings.cleanOnQuit)
                Toggle("On a schedule", isOn: $model.schedule.isEnabled)
                if model.schedule.isEnabled {
                    Picker("Repeat", selection: $model.schedule.frequency) {
                        Text("Every day").tag(CleanupSchedule.Frequency.daily)
                        Text("Every few hours").tag(CleanupSchedule.Frequency.interval)
                    }
                    switch model.schedule.frequency {
                    case .daily:
                        DatePicker("Time", selection: scheduleTime, displayedComponents: .hourAndMinute)
                    case .interval:
                        Stepper("Every \(model.schedule.intervalHours) hours", value: $model.schedule.intervalHours, in: 1...48)
                    }
                    if let next = model.nextScheduledRun {
                        LabeledContent("Next cleanup", value: next.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            } header: {
                Text("When to Clean")
            } footer: {
                Text("A browser that is open when a scheduled cleanup is due is cleaned as soon as it quits.")
            }

            Section {
                if model.browsers.isEmpty {
                    Text("No supported browsers were found.")
                        .foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
                        GridRow {
                            Text("Browser")
                            Text("Cookies")
                            Text("History")
                            Text("Cache")
                            Text("All")
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        ForEach(model.browsers) { browser in
                            GridRow {
                                browserLabel(browser)
                                automationToggle("Cookies", browser, .cookies)
                                automationToggle("History", browser, .history)
                                automationToggle("Cache", browser, .cache)
                                allAutomationToggle(browser)
                            }
                            if expandedBrowserIDs.contains(browser.id) {
                                ForEach(browser.profiles) { profile in
                                    GridRow {
                                        // Lines the checkbox up with the browser's icon.
                                        profileToggle(profile, of: browser)
                                            .padding(.leading, Self.disclosureWidth + 6)
                                    }
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("What to Clean")
            }

            Section {
                Picker("Sync every", selection: $model.settings.autoSyncSeconds) {
                    ForEach(Self.autoSyncIntervals, id: \.self) { seconds in
                        Text(Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .wide)))
                            .tag(seconds)
                    }
                }
            } header: {
                Text("Auto Sync")
            } footer: {
                Text("Turn on auto sync for a browser, or for all browsers, with the button in the toolbar above their data. It only runs while this window is open.")
            }

            Section {
                HStack {
                    Button("Clean Now") { model.cleanNow() }
                        .disabled(!model.hasAutomaticCleanups)
                    Spacer()
                    Text("Runs the cleanup above on every closed browser.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Automation")
    }

    private var scheduleTime: Binding<Date> {
        Binding {
            Calendar.current.date(bySettingHour: model.schedule.hour, minute: model.schedule.minute, second: 0, of: .now) ?? .now
        } set: { date in
            let components = Calendar.current.dateComponents([.hour, .minute], from: date)
            var schedule = model.schedule
            schedule.hour = components.hour ?? 0
            schedule.minute = components.minute ?? 0
            model.schedule = schedule
        }
    }

    private func automationToggle(_ title: String, _ browser: InstalledBrowser, _ kind: DataKind) -> some View {
        Toggle(title, isOn: Binding {
            isAutomated(kind, browser)
        } set: { isOn in
            setAutomation([kind], isOn, for: browser)
        })
        .toggleStyle(.checkbox)
        .labelsHidden()
    }

    /// Turns every kind of data on when any of them is off, and all of them off when they're all on.
    private func allAutomationToggle(_ browser: InstalledBrowser) -> some View {
        Toggle("All", isOn: Binding {
            DataKind.allCases.allSatisfy { isAutomated($0, browser) }
        } set: { isOn in
            setAutomation(DataKind.allCases, isOn, for: browser)
        })
        .toggleStyle(.checkbox)
        .labelsHidden()
    }

    /// The browser's name, which shows or hides the profiles to clean below it.
    private func browserLabel(_ browser: InstalledBrowser) -> some View {
        let isExpanded = expandedBrowserIDs.contains(browser.id)
        return Button {
            if isExpanded {
                expandedBrowserIDs.remove(browser.id)
            } else {
                expandedBrowserIDs.insert(browser.id)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: Self.disclosureWidth)
                BrowserIcon(definition: browser.definition)
                Text(browser.name)
                if let summary = skippedProfilesSummary(browser) {
                    Text(summary)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Hide profiles" : "Choose which profiles are cleaned")
    }

    /// "1 of 3 profiles" when some profiles are left alone, so it shows while the profiles are hidden.
    private func skippedProfilesSummary(_ browser: InstalledBrowser) -> String? {
        let cleaned = browser.profiles.filter(model.settings.automation(for: browser.id).cleans).count
        guard cleaned < browser.profiles.count else { return nil }
        return cleaned == 0 ? "No profiles" : "\(cleaned) of \(browser.profiles.count) profiles"
    }

    private func profileToggle(_ profile: BrowserProfile, of browser: InstalledBrowser) -> some View {
        Toggle(profile.name, isOn: Binding {
            model.settings.automation(for: browser.id).cleans(profile)
        } set: { isOn in
            if isOn {
                model.settings.automation[browser.id, default: BrowserAutomation()].skippedProfiles.remove(profile.id)
            } else {
                model.settings.automation[browser.id, default: BrowserAutomation()].skippedProfiles.insert(profile.id)
            }
        })
        .toggleStyle(.checkbox)
    }

    private func isAutomated(_ kind: DataKind, _ browser: InstalledBrowser) -> Bool {
        // Data CookieEater isn't allowed to open is never cleaned, so it shows as off.
        model.settings.automation(for: browser.id)[kind] && !model.isBlocked(kind, browserID: browser.id)
    }

    private func setAutomation(_ kinds: [DataKind], _ isOn: Bool, for browser: InstalledBrowser) {
        let blocked = isOn ? kinds.filter { model.isBlocked($0, browserID: browser.id) } : []
        for kind in kinds where !blocked.contains(kind) {
            model.settings.automation[browser.id, default: BrowserAutomation()][kind] = isOn
        }
        guard !blocked.isEmpty else { return }
        // Ask for the folders outside the toggle's action; each checkbox turns on once its access is allowed.
        Task {
            model.ensureAccess(blocked, for: browser)
            for kind in blocked where !model.isBlocked(kind, browserID: browser.id) {
                model.settings.automation[browser.id, default: BrowserAutomation()][kind] = true
            }
        }
    }
}
