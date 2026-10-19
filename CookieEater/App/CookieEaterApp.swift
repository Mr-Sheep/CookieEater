import SwiftUI

@main
struct CookieEaterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("CookieEater", id: WindowID.main) {
            ContentView()
                .environment(model)
                .frame(minWidth: 860, minHeight: 520)
        }
        .defaultSize(width: 1080, height: 700)
        .defaultLaunchBehavior(model.settings.showWindowAtLaunch ? .presented : .suppressed)

        MenuBarExtra("CookieEater", image: "MenuBarIcon") {
            MenuBarContent()
                .environment(model)
        }
    }
}

enum WindowID {
    static let main = "main"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Without a window, CookieEater lives in the menu bar only. The window brings the Dock icon back.
        if !SettingsStore.loadSettings().showWindowAtLaunch {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
