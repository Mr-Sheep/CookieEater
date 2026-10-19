import SwiftUI

private enum ProjectLink {
    static let repository = URL(string: "https://github.com/Mr-Sheep/CookieEater")!
    static let releases = URL(string: "https://github.com/Mr-Sheep/CookieEater/releases")!
    static let license = URL(string: "https://github.com/Mr-Sheep/CookieEater/blob/master/LICENSE")!
}

struct AboutCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About CookieEater") {
            openWindow(id: WindowID.about)
            NSApp.activate()
        }
    }
}

struct AboutView: View {
    @State private var showsAcknowledgements = true

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)

            Text("CookieEater")
                .font(.title.weight(.semibold))
                .padding(.top, 8)
            Text(versionText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 2)

            Text("Inspect and clean up your browsers' cookies, history, and caches.")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)

            HStack(spacing: 10) {
                Link(destination: ProjectLink.repository) {
                    Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: ProjectLink.releases) {
                    Label("Release Notes", systemImage: "doc.text")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding(.top, 12)

            Divider()
                .padding(.vertical, 12)

            VStack(spacing: 4) {
                Text("Free and open source under the [MIT License](\(ProjectLink.license)).")
                    .foregroundStyle(.secondary)
                Button {
                    showsAcknowledgements.toggle()
                } label: {
                    HStack(spacing: 3) {
                        Text("Acknowledgements")
                        Image(systemName: "chevron.right")
                            .imageScale(.small)
                            .rotationEffect(.degrees(showsAcknowledgements ? 90 : 0))
                    }
                }
                .buttonStyle(.link)
            }
            .font(.footnote)

            if showsAcknowledgements {
                CreditsText()
                    .frame(height: 100)
                    .background(.quinary, in: .rect(cornerRadius: 8))
                    .padding(.top, 12)
            }
        }
        .padding([.horizontal, .bottom], 24)
        .frame(width: 380)
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(version) (\(build))"
    }
}

private struct CreditsText: NSViewRepresentable {
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 14)
        if let url = Bundle.main.url(forResource: "Credits", withExtension: "rtf"),
           let credits = try? NSMutableAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                                        documentAttributes: nil) {
            credits.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: credits.length))
            textView.textStorage?.setAttributedString(credits)
        }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}
