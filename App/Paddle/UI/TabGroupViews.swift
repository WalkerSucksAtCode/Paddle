import AppKit
import PaddleCore
import SwiftUI

// MARK: - Colours

extension TabGroupColor {
    /// The label fill as 0xRRGGBB. Neighbouring colours in `allCases` differ in brightness as well as hue, so the
    /// groups can be told apart without seeing the hue; the name is always shown too.
    func hex(_ scheme: ColorScheme) -> UInt32 {
        switch (self, scheme == .dark) {
        case (.grey, false): 0x6B7280
        case (.blue, false): 0x1E40AF
        case (.red, false): 0xE5484D
        case (.yellow, false): 0xFACC15
        case (.green, false): 0x15803D
        case (.pink, false): 0xF9A8D4
        case (.purple, false): 0x6D28D9
        case (.cyan, false): 0x67E8F9
        case (.orange, false): 0xF97316
        case (.grey, true): 0xA1A1AA
        case (.blue, true): 0x3B63E0
        case (.red, true): 0xF0626A
        case (.yellow, true): 0xFDE047
        case (.green, true): 0x2F9E5B
        case (.pink, true): 0xF9B4DA
        case (.purple, true): 0x9370F7
        case (.cyan, true): 0x67E8F9
        case (.orange, true): 0xFB923C
        }
    }

    func fill(_ scheme: ColorScheme) -> Color { Self.color(hex(scheme)) }

    /// White or near-black, whichever contrasts more with the fill.
    func labelText(_ scheme: ColorScheme) -> Color {
        Self.color(Self.textHex(hex(scheme)))
    }

    /// The text colour (0xRRGGBB) with the higher WCAG contrast against `fill`.
    static func textHex(_ fill: UInt32) -> UInt32 {
        contrast(fill, 0xFFFFFF) >= contrast(fill, 0x111111) ? 0xFFFFFF : 0x111111
    }

    /// WCAG contrast ratio between two 0xRRGGBB colours.
    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private static func luminance(_ hex: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let c = Double((hex >> shift) & 0xFF) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }

    private static func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - Label

/// The chip before a group's first tab: its name on the group's colour. Click collapses; the right-click menu renames.
struct TabGroupLabel: View {
    let group: TabGroup
    let model: BrowserModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.chromeScale) private var scale
    @State private var draft = ""
    @State private var selection: TextSelection?
    @FocusState private var focused: Bool

    private var isRenaming: Bool { model.renamingGroupID == group.id }
    private var count: Int { model.tabs(in: group).count }

    /// The label's width: its text, capped at 120 pt. Also used by the strip to size itself.
    static func width(for group: TabGroup, count: Int, renaming: Bool, scale: Double = 1) -> CGFloat {
        if renaming { return 120 * scale }
        let text = text(for: group, count: count)
        let font = NSFont.systemFont(ofSize: 11 * scale, weight: .semibold)
        let textWidth = text.isEmpty ? 0 : (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
        let circle: CGFloat = group.name.isEmpty ? 12 : 0
        let gap: CGFloat = circle > 0 && !text.isEmpty ? 4 : 0
        return min(120 * scale, max(22, textWidth + circle + gap + 16))
    }

    /// What the label spells: the name, plus the hidden count when collapsed ("Work · 3"; "3" for a nameless group).
    static func text(for group: TabGroup, count: Int) -> String {
        guard group.isCollapsed else { return group.name }
        return group.name.isEmpty ? "\(count)" : "\(group.name) · \(count)"
    }

    private var foreground: Color { group.color.labelText(scheme) }

    var body: some View {
        HStack(spacing: 4) {
            if isRenaming {
                TextField("Group name", text: $draft, selection: $selection)
                    .textFieldStyle(.plain)
                    .chromeFont(size: 11, weight: .semibold)
                    .foregroundStyle(foreground)
                    .focused($focused)
                    .onSubmit { commit() }
                    .onKeyPress(.escape) {
                        model.renamingGroupID = nil
                        return .handled
                    }
                    .onChange(of: focused) { _, focused in
                        if !focused { commit() }
                    }
                    .onAppear {
                        draft = group.name
                        // Next turn, so a click's own focus change can't take it straight back.
                        DispatchQueue.main.async {
                            focused = true
                            selection = TextSelection(range: draft.startIndex..<draft.endIndex)
                        }
                    }
            } else {
                if group.name.isEmpty {
                    Circle().fill(foreground).frame(width: 12, height: 12)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 0.5))
                }
                let text = Self.text(for: group, count: count)
                if !text.isEmpty {
                    Text(text)
                        .chromeFont(size: 11, weight: .semibold)
                        .foregroundStyle(foreground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(width: Self.width(for: group, count: count, renaming: isRenaming, scale: scale), height: 22)
        .background(RoundedRectangle(cornerRadius: 6).fill(group.color.fill(scheme)))
        .contentShape(Rectangle())
        .onTapGesture { if !isRenaming { model.toggleCollapsed(group) } }
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)),
                  let dragged = model.tabs.first(where: { $0.id == id }), !dragged.isPinned else { return false }
            model.add(dragged, to: group)
            return true
        }
        // While renaming, the text field is what VoiceOver reaches.
        .accessibilityElement(children: isRenaming ? .contain : .ignore)
        .accessibilityLabel(Self.spokenLabel(group, count: count))
        .accessibilityAddTraits(isRenaming ? [] : .isButton)
        .accessibilityAction { model.toggleCollapsed(group) }
        .accessibilityAction(named: "Rename Group") { model.renamingGroupID = group.id }
        .help(group.isCollapsed ? "Click to show the group's tabs" : "Click to collapse the group")
        .contextMenu { TabGroupContextMenu(group: group, model: model) }
    }

    /// "Group Work, Blue, 3 tabs, collapsed".
    static func spokenLabel(_ group: TabGroup, count: Int) -> String {
        let name = group.name.isEmpty ? "Unnamed" : group.name
        return "Group \(name), \(group.color.title), \(count) \(count == 1 ? "tab" : "tabs"), \(group.isCollapsed ? "collapsed" : "expanded")"
    }

    /// Return or focus loss keeps the edited name. Escape clears `renamingGroupID` first, so it never lands here.
    private func commit() {
        guard isRenaming else { return }
        model.renameGroup(group, to: draft)
        model.renamingGroupID = nil
    }
}
