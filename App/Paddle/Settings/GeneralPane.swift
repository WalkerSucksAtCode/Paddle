import SwiftUI

/// Settings > General: home page, new tab page, search engine and search suggestions. Placeholder until its wave fills it in.
struct GeneralPane: View {
    let model: SettingsModel

    var body: some View {
        SettingsForm {
            Section("General") {
                Text("Home page, new tab page and search settings will go here (homepage, newTabPage, searchTemplate, searchSuggestTemplate).")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
