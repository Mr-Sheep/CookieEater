import SwiftUI

/// The browser's app icon, or a globe when the app isn't installed.
struct BrowserIcon: View {
    let definition: BrowserDefinition
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let url = definition.bundleIDs.lazy.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false)))
                    .resizable()
            } else {
                Image(systemName: "globe")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

struct RunningIndicator: View {
    var body: some View {
        Circle()
            .fill(.green)
            .frame(width: 6, height: 6)
            .help("Running")
    }
}
