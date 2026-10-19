import SwiftUI

struct BrowsersView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                if model.installedBrowsers.isEmpty {
                    Text("No supported browsers were found.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.installedBrowsers) { browser in
                    Toggle(isOn: Binding {
                        !model.isExcluded(browser.id)
                    } set: { isIncluded in
                        model.setExcluded(!isIncluded, browserID: browser.id)
                    }) {
                        HStack(spacing: 10) {
                            BrowserIcon(definition: browser.definition, size: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(browser.name)
                                Text(details(for: browser))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("Browsers on This Mac")
            } footer: {
                Text("Turn off a browser to exclude it. CookieEater doesn't read an excluded browser's cookies or history, and never cleans it, by hand or automatically.")
            }

            Section {
                Picker("Read cookies and history", selection: Binding {
                    model.settings.chromiumReading
                } set: {
                    model.setChromiumReading($0)
                }) {
                    Text("In place").tag(DatabaseReading.inPlace)
                    Text("From a temporary copy").tag(DatabaseReading.copy)
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Chromium-Based Reading")
            } footer: {
                Text("Chromium-based browsers keep their cookies and history locked while they're open. From a temporary copy, they can be read while the browser is open, and each copy is deleted as soon as it has been read. In place, their files are read where they are, once the browser quits. Firefox and Safari are always read in place, without changing their files.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Browsers")
    }

    private func details(for browser: InstalledBrowser) -> String {
        guard !model.isExcluded(browser.id) else { return "Excluded" }
        let profiles = browser.profiles.count == 1 ? "1 profile" : "\(browser.profiles.count) profiles"
        let count = model.cookies.count { $0.browserID == browser.id }
        return "\(profiles) · \(count == 1 ? "1 cookie" : "\(count.formatted()) cookies")"
    }
}
