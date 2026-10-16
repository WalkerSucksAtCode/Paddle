import PaddleCore
import SwiftUI

/// Saving and checking one top-level key, for the panes that edit plain values (General, Tabs & Memory, Privacy).
extension SettingsModel {
    /// A value equal to its default removes the key from config.json (`ConfigFile.apply`).
    func saveKey(_ key: PaddleConfig.CodingKeys, _ value: JSONValue) async {
        await save([ConfigChange(key.rawValue, value)])
    }

    /// What `ConfigValidator` would say about `key` once `edit` is applied to the file's settings, so a pane can
    /// refuse an error before it is written and show a warning next to the control.
    func issues(for key: PaddleConfig.CodingKeys, after edit: (inout PaddleConfig) -> Void) -> [ConfigIssue] {
        var candidate = file
        edit(&candidate)
        return ConfigValidator.issues(candidate, actionNames: Set(MainMenu.actionNames)).filter { $0.key == key }
    }
}

/// A control's validation messages under it: an icon and text for each (never colour alone).
struct ConfigIssueList: View {
    let issues: [ConfigIssue]

    var body: some View {
        ForEach(issues) { issue in
            Label {
                Text(issue.message).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(issue.severity == .error ? .red : .yellow)
                    .accessibilityLabel(issue.severity == .error ? "Error" : "Warning")
            }
            .font(.callout)
        }
    }
}

struct SettingsCaption: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
