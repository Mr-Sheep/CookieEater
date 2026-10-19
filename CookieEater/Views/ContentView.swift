import SwiftUI

enum SidebarItem: Hashable {
    case allBrowsers
    case browser(String)
    case exceptions
    case automation
    case activity
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem? = .allBrowsers

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Cookies") {
                    Label("All Browsers", systemImage: "square.stack.3d.up")
                        .badge(model.cookies.count)
                        .tag(SidebarItem.allBrowsers)
                    ForEach(model.browsers) { browser in
                        BrowserSidebarRow(browser: browser)
                            .tag(SidebarItem.browser(browser.id))
                    }
                }
                Section("Settings") {
                    Label("Exceptions", systemImage: "checkmark.shield")
                        .badge(model.settings.exceptions.count)
                        .tag(SidebarItem.exceptions)
                    Label("Automation", systemImage: "clock.arrow.2.circlepath")
                        .tag(SidebarItem.automation)
                    Label("Activity", systemImage: "list.bullet.rectangle")
                        .tag(SidebarItem.activity)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            VStack(spacing: 0) {
                if !model.hasFullDiskAccess {
                    FullDiskAccessBanner()
                    Divider()
                }
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .alert(model.quitPrompt.map { "Quit \($0.browserNames)?" } ?? "",
               isPresented: Binding(get: { model.quitPrompt != nil }, set: { if !$0 { model.quitPrompt = nil } }),
               presenting: model.quitPrompt) { prompt in
            Button("Quit and Continue") { model.confirmQuit(prompt) }
            Button("Cancel", role: .cancel) { model.quitPrompt = nil }
        } message: { prompt in
            Text("\(prompt.browserNames) keeps this data in memory while it’s open and would write it back. CookieEater will quit it, then finish removing the data.")
        }
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .allBrowsers, nil:
            CookiesView(scope: .allBrowsers)
        case .browser(let id):
            CookiesView(scope: .browser(id))
                .id(id)
        case .exceptions:
            ExceptionsView()
        case .automation:
            AutomationView()
        case .activity:
            ActivityView()
        }
    }
}

private struct BrowserSidebarRow: View {
    @Environment(AppModel.self) private var model
    let browser: InstalledBrowser

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(browser.name)
                if model.runningBrowserIDs.contains(browser.id) {
                    RunningIndicator()
                }
            }
        } icon: {
            BrowserIcon(definition: browser.definition)
        }
        .badge(model.cookies.count { $0.browserID == browser.id })
    }
}

private struct FullDiskAccessBanner: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Safari needs Full Disk Access")
                    .font(.headline)
                Text("macOS protects Safari’s cookies and history. Turn on CookieEater in Privacy & Security › Full Disk Access, then come back.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open System Settings") {
                NSWorkspace.shared.open(Permissions.fullDiskAccessSettingsURL)
            }
        }
        .padding(12)
        .background(.orange.opacity(0.08))
    }
}
