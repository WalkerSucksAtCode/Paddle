import SwiftUI

/// Settings > Sites: per-site settings. Placeholder until its wave fills it in.
struct SitesPane: View {
    let model: SettingsModel

    var body: some View {
        SettingsForm {
            Section("Sites") {
                Text("Per-site zoom, JavaScript, autoplay, content blocking, location and user agents will go here (sites, siteUserAgents).")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
