import SwiftUI

/// Settings > Privacy & Blocking: history, website data and content blocking. Placeholder until its wave fills it in.
struct PrivacyPane: View {
    let model: SettingsModel

    var body: some View {
        SettingsForm {
            Section("Privacy & Blocking") {
                Text("History retention, website data and content blocking will go here (historyDays, contentBlocking, filterLists, filterUpdateDays).")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
