import SwiftUI

/// Settings > Shortcuts: menu shortcuts. Placeholder until its wave fills it in.
struct ShortcutsPane: View {
    let model: SettingsModel

    var body: some View {
        SettingsForm {
            Section("Shortcuts") {
                Text("Rebinding menu shortcuts will go here (shortcuts).")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
