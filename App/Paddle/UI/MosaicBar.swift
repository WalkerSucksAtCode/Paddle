import PaddleCore
import SwiftUI

extension PaneArrangement {
    var title: String {
        switch self {
        case .columns: "Columns"
        case .rows: "Rows"
        case .grid: "Grid"
        case .mainAndStack: "Main and Stack"
        }
    }

    var symbol: String {
        switch self {
        case .columns: "rectangle.split.3x1"
        case .rows: "rectangle.split.1x2"
        case .grid: "rectangle.split.2x2"
        case .mainAndStack: "rectangle.leadinghalf.inset.filled"
        }
    }

    /// The Tabs > Mosaic Layout action name, for the shortcut in a button's help.
    var actionName: String {
        switch self {
        case .columns: "arrangeColumns"
        case .rows: "arrangeRows"
        case .grid: "arrangeGrid"
        case .mainAndStack: "arrangeMainAndStack"
        }
    }
}

/// The window toolbar's middle while a Mosaic shows (each pane has its own address field): empty space that drags the
/// window like the title bar, with the Mosaic's controls in the middle: its icon (click to choose one), its name
/// (click to rename) and pane count,
/// the layouts, Even Out, Rotate, Swap (two panes), Add Pane, Reload All, Zoom Pane, a settings menu (most panes, pane
/// toolbars, the gap, Mute Other Panes) and End Mosaic.
struct MosaicToolbarArea: View {
    let model: BrowserModel
    let split: BrowserModel.Split
    let app: AppModel

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 8)
            MosaicBar(model: model, split: split, app: app)
                .fixedSize()
            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Behind the bar: the empty space on both sides (and between its buttons) moves the window (`mosaicWindowDrag`).
        .background(WindowDragArea().allowsHitTesting(app.config.mosaicWindowDrag))
    }
}

struct MosaicBar: View {
    let model: BrowserModel
    let split: BrowserModel.Split
    let app: AppModel
    @State private var renaming = false
    @State private var choosingIcon = false
    @Environment(\.chromeTheme) private var theme

    private var count: Int { split.layout.count }
    private var accent: Color { theme?.accent ?? Color.accentColor }

    var body: some View {
        HStack(spacing: 1) {
            Button { choosingIcon = true } label: {
                MosaicIconView(layout: split.layout, size: 12)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Choose an icon for this Mosaic")
            .accessibilityLabel("Choose Icon")
            .popover(isPresented: $choosingIcon, arrowEdge: .bottom) {
                MosaicIconPicker(model: model, splitID: split.id)
            }
            Button { renaming = true } label: {
                HStack(spacing: 5) {
                    Text(model.displayName(of: split))
                        .chromeFont(size: 12, weight: .medium)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 160, alignment: .leading)
                    Text("\(count)/\(max(model.maxPanes, count))")
                        .chromeFont(size: 10, weight: .medium)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.trailing, 6)
                .frame(height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Rename this Mosaic")
            .accessibilityLabel("Mosaic \(model.displayName(of: split)), \(count) of \(model.maxPanes) panes. Rename")
            .popover(isPresented: $renaming, arrowEdge: .bottom) {
                ViewNameField(split: split, model: model) { renaming = false }
            }

            separator
            // One lit even when two layouts give the same shape (two panes: Columns and Grid).
            let current = PaneArrangement.allCases.first(where: split.layout.isArranged)
            ForEach(PaneArrangement.allCases, id: \.self) { arrangement in
                let current = arrangement == current
                icon(arrangement.symbol, arrangement.title, action: arrangement.actionName, selected: current) {
                    model.arrangeMosaic(arrangement)
                }
            }
            separator
            icon("equal.square", "Even Out Panes", action: "evenOutPanes") { model.equalizePanes() }
            icon("arrow.triangle.2.circlepath", "Rotate Panes", action: "rotatePanes") { model.rotatePanes() }
            if count == 2 {
                icon("arrow.left.arrow.right", "Swap Panes", action: "swapMosaicPanes") { model.swapSplitSides() }
            }
            icon("plus.rectangle.on.rectangle", model.canAddPane ? "Add Pane" : "Add Pane: this Mosaic is full (\(model.maxPanes) panes)",
                 action: "addPane", enabled: model.canAddPane) { model.addPaneToMosaic() }
            icon("arrow.clockwise", "Reload All Panes", action: "reloadAllPanes") { model.reloadAllPanes() }
            let zoomed = model.selectedTab.map { model.zoomedPaneID == $0.id } ?? false
            icon(zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                 zoomed ? "Unzoom Pane" : "Zoom Pane: the focused pane fills the Mosaic for now", action: "zoomPane", selected: zoomed) {
                model.toggleZoomPane()
            }
            separator
            settingsMenu
            icon("xmark.rectangle", "End Mosaic: the tabs stay in the strip", action: "toggleMosaic") {
                if let selected = model.selectedTab { model.endSplit(of: selected) }
            }
        }
        .padding(.horizontal, 3)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mosaic controls")
    }

    /// The gap choices offered in the menus: `mosaicGap` takes any whole number in its range.
    static let gaps: [(title: String, points: Double)] = [("Tight (2 pt)", 2), ("Normal (6 pt)", 6), ("Roomy (12 pt)", 12)]

    private var separator: some View {
        Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 1, height: 14).padding(.horizontal, 3)
            .accessibilityHidden(true)
    }

    private var settingsMenu: some View {
        Menu {
            Picker("Most Panes in a Mosaic", selection: Binding(
                get: { model.maxPanes },
                set: { value in Task { await app.setMosaicMaxPanes(value) } }
            )) {
                ForEach(2...PaneLayout.maxPanes, id: \.self) { n in Text("\(n) panes").tag(n) }
            }
            .pickerStyle(.menu)
            Picker("Pane Toolbars", selection: Binding(
                get: { app.config.mosaicPaneBars },
                set: { value in Task { await app.setMosaicConfig([ConfigChange("mosaicPaneBars", .string(value.rawValue))]) } }
            )) {
                Text("Always Shown").tag(MosaicPaneBars.always)
                Text("Shown on Hover").tag(MosaicPaneBars.hover)
            }
            .pickerStyle(.menu)
            Picker("Space Between Panes", selection: Binding(
                get: { app.config.mosaicGap },
                set: { value in Task { await app.setMosaicConfig([ConfigChange("mosaicGap", .number(value))]) } }
            )) {
                ForEach(MosaicBar.gaps, id: \.points) { gap in Text(gap.title).tag(gap.points) }
                if !MosaicBar.gaps.contains(where: { $0.points == app.config.mosaicGap }) {
                    Text("\(Int(app.config.mosaicGap)) pt").tag(app.config.mosaicGap)
                }
            }
            .pickerStyle(.menu)
            Picker("Animation", selection: Binding(
                get: { app.config.mosaicAnimation },
                set: { value in Task { await app.setMosaicConfig([ConfigChange("mosaicAnimation", .string(value.rawValue))]) } }
            )) {
                Text("Follow Reduce Motion").tag(MosaicAnimation.system)
                Text("Full").tag(MosaicAnimation.full)
                Text("Reduced").tag(MosaicAnimation.reduced)
                Text("Off").tag(MosaicAnimation.off)
            }
            .pickerStyle(.menu)
            Picker("Focused Pane", selection: Binding(
                get: { app.config.mosaicFocusMarker },
                set: { value in Task { await app.setMosaicConfig([ConfigChange("mosaicFocusMarker", .string(value.rawValue))]) } }
            )) {
                Text("Edge").tag(MosaicFocusMarker.ring)
                Text("Dim the Others").tag(MosaicFocusMarker.dim)
                Text("No Marker").tag(MosaicFocusMarker.none)
            }
            .pickerStyle(.menu)
            Divider()
            Button("Mute Other Panes") { model.muteOtherPanes() }
            Divider()
            Button("Mosaic Settings…") { app.showSettings(pane: .mosaic) }
        } label: {
            Image(systemName: "slider.horizontal.3").chromeFont(size: 11, weight: .medium)
        }
        .menuStyle(.borderlessButton)
        // The other icons' ink, not the accent a borderless menu takes.
        .tint(.primary)
        .menuIndicator(.hidden)
        .frame(width: 26, height: 24)
        .help("Mosaic settings")
        .accessibilityLabel("Mosaic settings")
    }

    private func icon(
        _ symbol: String, _ title: String, action name: String, enabled: Bool = true, selected: Bool = false,
        perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            Image(systemName: symbol)
                .chromeFont(size: 12, weight: .medium)
                .foregroundStyle(selected ? accent : Color.primary)
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(selected ? accent.opacity(0.16) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(Self.help(title, action: name))
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// `title` with the action's current shortcut, as the menu bar shows it.
    private static func help(_ title: String, action name: String) -> String {
        guard let item = MainMenu.item(named: name), !item.keyEquivalent.isEmpty else { return title }
        let flags = item.keyEquivalentModifierMask
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return "\(title) (\(text)\(item.keyEquivalent.uppercased()))"
    }
}
