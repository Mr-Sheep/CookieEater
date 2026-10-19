import SwiftUI

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open CookieEater") {
            openWindow(id: WindowID.main)
            NSApp.activate()
        }
        Button("Clean Now") { model.cleanNow() }
            .disabled(!model.hasAutomaticCleanups)
        Divider()
        if model.cleanupsInProgress > 0 {
            Text("Cleaning…")
        }
        if let next = model.nextScheduledRun {
            Text("Next cleanup: \(next.formatted(date: .abbreviated, time: .shortened))")
        }
        if model.settings.cleanOnQuit {
            Text("Cleaning browsers when they quit")
        }
        let waiting = model.browsers.filter { model.waitingBrowserIDs.contains($0.id) }.map(\.name)
        if !waiting.isEmpty {
            Text("Waiting for \(waiting.formatted(.list(type: .and))) to quit")
        }
        Divider()
        Button("Quit CookieEater") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
