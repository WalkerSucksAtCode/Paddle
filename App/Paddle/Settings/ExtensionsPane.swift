import SwiftUI

/// Settings > Extensions: extensions in the extensions folder. Placeholder until its wave fills it in.
struct ExtensionsPane: View {
    let model: SettingsModel

    var body: some View {
        SettingsForm {
            Section("Extensions") {
                Text("Turning extensions on and off, and running them in private windows, will go here (extensions, extensionsInPrivate).")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
