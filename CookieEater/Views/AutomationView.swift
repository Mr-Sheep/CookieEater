import SwiftUI

struct AutomationView: View {
    private static let disclosureWidth: CGFloat = 12
    /// The choices for how often auto sync reads the data again, in seconds.
    private static let autoSyncIntervals = [5, 10, 15, 30, 60, 120, 300]

    @Environment(AppModel.self) private var model
    /// Browsers whose profiles are shown.
    @State private var expandedBrowserIDs: Set<String> = []
    /// Options waiting for their folders to be allowed, by browser ID. A checkbox that changes several profiles or kinds
    /// of data asks for all of their folders at once.
    @State private var awaitingAccess: [String: [(kind: DataKind, profileID: String?)]] = [:]

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
                                .frame(maxWidth: .infinity, alignment: .leading)
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
                                automationToggles(browser, profile: nil)
                            }
                            if browser.profiles.count > 1 && expandedBrowserIDs.contains(browser.id) {
                                ForEach(browser.profiles) { profile in
                                    GridRow {
                                        // Lines the name up with the browser's icon.
                                        Text(profile.name)
                                            .padding(.leading, Self.disclosureWidth + 6)
                                        automationToggles(browser, profile: profile)
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

    /// The checkboxes for one profile, or for every profile of the browser when `profile` is nil. A browser's checkbox
    /// is mixed when its profiles differ, and changes all of them, including profiles added later.
    @ViewBuilder
    private func automationToggles(_ browser: InstalledBrowser, profile: BrowserProfile?) -> some View {
        automationToggle("Cookies", [.cookies], browser, profile: profile)
        automationToggle("History", [.history], browser, profile: profile)
        automationToggle("Cache", [.cache], browser, profile: profile)
        // Turns every kind of data on when any of them is off, and all of them off when they're all on.
        automationToggle("All", DataKind.allCases, browser, profile: profile)
    }

    private func automationToggle(_ title: String, _ kinds: [DataKind], _ browser: InstalledBrowser,
                                  profile: BrowserProfile?) -> some View {
        let shownProfiles = profile.map { [$0] } ?? browser.profiles
        let sources = shownProfiles.flatMap { shown in
            kinds.map { kind in
                Binding {
                    isAutomated(kind, in: shown, of: browser)
                } set: { isOn in
                    setAutomation(kind, isOn, inProfile: profile?.id, of: browser)
                }
            }
        }
        return Toggle(title, sources: sources, isOn: \.self)
            .toggleStyle(.checkbox)
            .labelsHidden()
    }

    /// The browser's name, which shows or hides its profiles below it when it has several.
    @ViewBuilder
    private func browserLabel(_ browser: InstalledBrowser) -> some View {
        let isExpanded = expandedBrowserIDs.contains(browser.id)
        let label = HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: Self.disclosureWidth)
                .opacity(browser.profiles.count > 1 ? 1 : 0)
            BrowserIcon(definition: browser.definition)
            Text(browser.name)
        }
        if browser.profiles.count > 1 {
            Button {
                if isExpanded {
                    expandedBrowserIDs.remove(browser.id)
                } else {
                    expandedBrowserIDs.insert(browser.id)
                }
            } label: {
                label.contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Hide profiles" : "Choose what is cleaned in each profile")
        } else {
            label
        }
    }

    private func isAutomated(_ kind: DataKind, in profile: BrowserProfile, of browser: InstalledBrowser) -> Bool {
        // Data CookieEater isn't allowed to open is never cleaned, so it shows as off.
        model.settings.automation(for: browser.id)[profile][kind] && !model.isBlocked(kind, browserID: browser.id)
    }

    private func setAutomation(_ kind: DataKind, _ isOn: Bool, inProfile profileID: String?, of browser: InstalledBrowser) {
        guard isOn && model.isBlocked(kind, browserID: browser.id) else {
            model.settings.automation[browser.id, default: BrowserAutomation()].set(kind, isOn, inProfile: profileID)
            return
        }
        let isFirst = awaitingAccess[browser.id] == nil
        awaitingAccess[browser.id, default: []].append((kind, profileID))
        guard isFirst else { return }
        // Ask for the folders outside the toggle's action, once it has changed every profile and kind of data; each
        // option turns on once its access is allowed.
        Task {
            let options = awaitingAccess.removeValue(forKey: browser.id) ?? []
            model.ensureAccess(DataKind.allCases.filter { kind in options.contains { $0.kind == kind } }, for: browser)
            for option in options where !model.isBlocked(option.kind, browserID: browser.id) {
                model.settings.automation[browser.id, default: BrowserAutomation()].set(option.kind, true, inProfile: option.profileID)
            }
        }
    }
}
