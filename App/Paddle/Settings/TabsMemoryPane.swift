import SwiftUI

/// Settings > Tabs & Memory: tab sleeping and the memory readout. Placeholder until its wave fills it in.
struct TabsMemoryPane: View {
    let model: SettingsModel

    var body: some View {
        SettingsForm {
            Section("Tabs & Memory") {
                Text("Tab sleeping and the memory readout will go here (tabSleepAfterMinutes, maxAwakeTabs, sleepPinnedTabs, showTabMemory).")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
