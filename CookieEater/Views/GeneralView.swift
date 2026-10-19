import ServiceManagement
import Sparkle
import SwiftUI

struct GeneralView: View {
    @Environment(AppModel.self) private var model
    /// Nil in builds that don't look for updates.
    let updater: SPUUpdater?

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                if model.loginItemNeedsApproval {
                    LabeledContent("Allow CookieEater in Login Items to finish turning this on.") {
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                Toggle("Open this window at launch", isOn: $model.settings.showWindowAtLaunch)
            } header: {
                Text("Startup")
            } footer: {
                Text("CookieEater keeps running in the menu bar after you close this window.")
            }

            Section {
                Toggle("Enable activity log", isOn: $model.settings.logsActivity)
            } header: {
                Text("Activity")
            }

            if let updater {
                UpdatesSection(updater: updater)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }
}

/// Sparkle keeps these preferences itself, so they're read from the updater as it changes them.
private struct UpdatesSection: View {
    let updater: SPUUpdater
    @State private var checksAutomatically = false
    @State private var canCheck = false

    var body: some View {
        Section {
            Toggle("Check for updates automatically", isOn: Binding {
                checksAutomatically
            } set: { isOn in
                updater.automaticallyChecksForUpdates = isOn
            })
            LabeledContent {
                Button("Check Now") { updater.checkForUpdates() }
                    .disabled(!canCheck)
            } label: {
                Text("Last checked")
                // Read again whenever a check finishes and `canCheck` turns back on.
                Text(updater.lastUpdateCheckDate?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
            }
        } header: {
            Text("Updates")
        }
        .onReceive(updater.publisher(for: \.automaticallyChecksForUpdates)) { checksAutomatically = $0 }
        .onReceive(updater.publisher(for: \.canCheckForUpdates)) { canCheck = $0 }
    }
}
