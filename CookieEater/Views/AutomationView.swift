import ServiceManagement
import SwiftUI

struct AutomationView: View {
    @Environment(AppModel.self) private var model

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
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        ForEach(model.browsers) { browser in
                            GridRow {
                                Label {
                                    Text(browser.name)
                                } icon: {
                                    BrowserIcon(definition: browser.definition)
                                }
                                automationToggle("Cookies", browser, .cookies)
                                automationToggle("History", browser, .history)
                                automationToggle("Cache", browser, .cache)
                            }
                        }
                    }
                }
            } header: {
                Text("What to Clean")
            } footer: {
                Text("Cookies from sites on the exception list are always kept. Excluded browsers are never cleaned.")
            }

            Section {
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                if model.loginItemNeedsApproval {
                    LabeledContent("Allow CookieEater in Login Items to finish turning this on.") {
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                Toggle("Open this window at launch", isOn: $model.settings.showWindowAtLaunch)
            } header: {
                Text("General")
            } footer: {
                Text("CookieEater keeps running in the menu bar after you close this window.")
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
            // Data CookieEater isn't allowed to open is never cleaned, so it shows as off.
            model.settings.automation(for: browser.id)[kind] && !model.isBlocked(kind, browserID: browser.id)
        } set: { isOn in
            guard isOn, model.isBlocked(kind, browserID: browser.id) else {
                model.settings.automation[browser.id, default: BrowserAutomation()][kind] = isOn
                return
            }
            // Ask for the folder outside the toggle's action; the checkbox turns on once access is allowed.
            Task {
                if model.ensureAccess([kind], for: browser) {
                    model.settings.automation[browser.id, default: BrowserAutomation()][kind] = true
                }
            }
        })
        .toggleStyle(.checkbox)
        .labelsHidden()
    }
}
