import SwiftUI

enum SidebarItem: Hashable {
    case allBrowsers
    case browser(String)
    case browsers
    case exceptions
    case automation
    case activity
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem? = .allBrowsers
    /// Shared by every browser, so switching browsers keeps the tab.
    @State private var dataKind = DataKind.cookies

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    Label("All Browsers", systemImage: "square.stack.3d.up")
                        .tag(SidebarItem.allBrowsers)
                    ForEach(model.browsers) { browser in
                        BrowserSidebarRow(browser: browser)
                            .tag(SidebarItem.browser(browser.id))
                    }
                }
                Section("Settings") {
                    Label("Browsers", systemImage: "macwindow.on.rectangle")
                        .tag(SidebarItem.browsers)
                    Label("Exceptions", systemImage: "checkmark.shield")
                        .badge(DataKind.allCases.reduce(0) { $0 + model.settings[exceptionsFor: $1].count })
                        .tag(SidebarItem.exceptions)
                    Label("Automation", systemImage: "clock.arrow.2.circlepath")
                        .tag(SidebarItem.automation)
                    Label("Activity", systemImage: "list.bullet.rectangle")
                        .tag(SidebarItem.activity)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert(model.quitPrompt.map { "Quit \($0.browserNames)?" } ?? "",
               isPresented: Binding(get: { model.quitPrompt != nil }, set: { if !$0 { model.quitPrompt = nil } }),
               presenting: model.quitPrompt) { prompt in
            Button("Quit and Continue") { model.confirmQuit(prompt) }
            Button("Cancel", role: .cancel) { model.quitPrompt = nil }
        } message: { prompt in
            Text("\(prompt.browserNames) keeps this data in memory while it's open and would write it back. CookieEater will quit it, then finish removing the data.")
        }
        .onChange(of: model.browsers.map(\.id)) { _, ids in
            // The selected browser was excluded or uninstalled.
            if case .browser(let id) = selection, !ids.contains(id) {
                selection = .allBrowsers
            }
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
            BrowserDataView(scope: .allBrowsers, kind: $dataKind)
        case .browser(let id):
            BrowserDataView(scope: .browser(id), kind: $dataKind)
                .id(id)
        case .browsers:
            BrowsersView()
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
        .contextMenu {
            Button("Exclude \(browser.name)") {
                model.setExcluded(true, browserID: browser.id)
            }
        }
    }
}
