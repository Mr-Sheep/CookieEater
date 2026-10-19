import Sparkle
import SwiftUI

@main
struct CookieEaterApp: App {
    /// Release builds carry the public key that updates are verified with. Other builds don't look for updates.
    private static let checksForUpdates = !(Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? "").isEmpty

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    private let updater = SPUStandardUpdaterController(startingUpdater: checksForUpdates, updaterDelegate: nil,
                                                       userDriverDelegate: nil)

    var body: some Scene {
        Window("CookieEater", id: WindowID.main) {
            ContentView(updater: Self.checksForUpdates ? updater.updater : nil)
                .environment(model)
                .frame(minWidth: 860, minHeight: 520)
        }
        .defaultSize(width: 1080, height: 700)
        .defaultLaunchBehavior(model.settings.showWindowAtLaunch ? .presented : .suppressed)
        .commands {
            CommandGroup(after: .appInfo) {
                if Self.checksForUpdates {
                    Button("Check for Updates…") { updater.checkForUpdates(nil) }
                }
            }
        }

        MenuBarExtra("CookieEater", image: "MenuBarIcon") {
            MenuBarContent(checkForUpdates: Self.checksForUpdates ? { updater.checkForUpdates(nil) } : nil)
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
