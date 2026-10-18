import PaddleCore
import SwiftUI

/// The items of a tab's right-click menu. Shared by the horizontal strip and the sidebar.
struct TabContextMenu: View {
    let tab: Tab
    let model: BrowserModel

    var body: some View {
        Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") { model.togglePin(tab) }
        Button("Rename Tab…") { model.renamingTabID = tab.id }
        Button("Duplicate Tab") { model.duplicate(tab) }
        Button(tab.isMuted ? "Unmute Tab" : "Mute Tab") { model.toggleMute(tab) }
            .disabled(!Tab.supportsMuting)
        Button("Mute Other Tabs") { model.muteOthers(tab) }
            .disabled(!Tab.supportsMuting)
        Button("Picture in Picture") { tab.togglePictureInPicture() }
            .disabled(!tab.isAwake || tab.isShowingErrorPage)
        Button("Put Tab to Sleep") { model.sleep(tab) }
            .disabled(!tab.isAwake || model.isVisible(tab))
        if model.split(of: tab) != nil {
            Button("Remove from View") { model.removeFromView(tab) }
            Button("End View") { model.endSplit(of: tab) }
        } else if let current = model.selectedTab, current !== tab, !tab.isPinned, !current.isPinned,
                  model.tabs.contains(where: { $0 === tab }),
                  model.split(of: current).map({ $0.layout.count < model.maxPanes }) ?? true {
            Button(model.split(of: current) == nil ? "Split with Current Tab" : "Add to Current View") { model.makeSplit(current, with: tab) }
        }
        if !tab.isPinned {
            Divider()
            Button("Add Tab to New Group") { model.addToNewGroup(tab) }
            let others = model.groups.filter { $0.id != tab.groupID }
            if !others.isEmpty {
                Menu("Add Tab to Group") {
                    ForEach(others) { group in
                        Button(group.name.isEmpty ? "Unnamed (\(group.color.title))" : group.name) { model.add(tab, to: group) }
                    }
                }
            }
            if tab.groupID != nil { Button("Remove from Group") { model.removeFromGroup(tab) } }
        }
        Divider()
        Button("Close Tab") { model.close(tab) }
        Button("Close Other Tabs") { model.closeOthers(tab) }
        Button("Close Tabs to the Right") { model.closeTabsToTheRight(tab) }
            .disabled(model.tabs.last === tab)
    }
}

/// The items of a tab group's right-click menu (its label in the strip or sidebar).
struct TabGroupContextMenu: View {
    let group: TabGroup
    let model: BrowserModel

    var body: some View {
        Button("Rename Group…") { model.renamingGroupID = group.id }
        Menu("Color") {
            ForEach(TabGroupColor.allCases, id: \.self) { color in
                // A toggle shows a real checkmark on the current colour.
                Toggle(color.title, isOn: Binding(
                    get: { color == group.color },
                    set: { _ in model.setColor(color, of: group) }
                ))
            }
        }
        Button("New Tab in Group") { model.newTab(in: group) }
        Divider()
        Button("Ungroup") { model.ungroup(group) }
        Button("Close Group") { model.closeGroup(group) }
        Button("Move Group to New Window") { model.moveGroupToNewWindow(group) }
    }
}
