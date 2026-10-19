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
                                automationToggle("Cookies", browser.id, \.cookies)
                                automationToggle("History", browser.id, \.history)
                                automationToggle("Cache", browser.id, \.cache)
                            }
                        }
                    }
                }
            } header: {
                Text("What to Clean")
            } footer: {
                Text("Cookies from sites on the exception list are always kept.")
            }

            Section {
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                if model.loginItemNeedsApproval {
                    LabeledContent("Allow CookieEater in Login Items to finish turning this on.") {
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                Toggle("Open this window at launch", isOn: $model.settings.showWindowAtLaunch)
                LabeledContent("Full Disk Access") {
                    HStack {
                        Text(model.hasFullDiskAccess ? "Granted" : "Not granted")
                            .foregroundStyle(model.hasFullDiskAccess ? .green : .orange)
                        Button("Open System Settings") {
                            NSWorkspace.shared.open(Permissions.fullDiskAccessSettingsURL)
                        }
                    }
                }
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

    private func automationToggle(_ title: String, _ browserID: String,
                                  _ option: WritableKeyPath<BrowserAutomation, Bool>) -> some View {
        Toggle(title, isOn: Binding {
            model.settings.automation(for: browserID)[keyPath: option]
        } set: { isOn in
            model.settings.automation[browserID, default: BrowserAutomation()][keyPath: option] = isOn
        })
        .toggleStyle(.checkbox)
        .labelsHidden()
    }
}
