import SwiftUI

/// Settings > Advanced: the file itself. Unknown keys, Tidy and the validation list come in a later wave.
struct AdvancedPane: View {
    let model: SettingsModel

    var body: some View {
        SettingsForm {
            Section("Advanced") {
                LabeledContent("config.json") {
                    Button("Edit config.json…") { SettingsBanner.editConfig() }
                        .help("Opens config.json in your editor. Paddle > Reload Config applies hand edits.")
                }
                Text("Unknown keys, Tidy and the list of config problems will go here.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
