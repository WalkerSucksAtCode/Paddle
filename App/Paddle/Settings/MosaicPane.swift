import AppKit
import PaddleCore
import SwiftUI

/// Settings > Mosaic: collapsible groups with a jump bar; single-column form rhythm.
struct MosaicPane: View {
    let model: SettingsModel

    @State private var openLayout = true
    @State private var openOpening = true
    @State private var openToolbars = false
    @State private var openFocus = false
    @State private var openMotion = false
    @State private var openDragging = false
    @State private var openStrip = false
    @State private var openBorders = false
    @State private var openBackground = false

    var body: some View {
        SettingsForm(maxColumns: 1, minColumnWidth: 520) {
            Section {
                mosaicJumpBar
            }
            mosaicCard("Layout", expanded: $openLayout) { layoutRows }
            mosaicCard("Opening", expanded: $openOpening) { openingRows }
            mosaicCard("Pane toolbars", expanded: $openToolbars) { toolbarRows }
            mosaicCard("Panes and focus", expanded: $openFocus) { focusRows }
            mosaicCard("Motion", expanded: $openMotion) { motionRows }
            mosaicCard("Dragging and handles", expanded: $openDragging) { draggingRows }
            mosaicCard("Tab strip", expanded: $openStrip) { stripRows }
            mosaicCard("Borders and look", expanded: $openBorders) { bordersRows }
            mosaicCard("In the background", expanded: $openBackground) { backgroundRows }
        }
    }

    private var mosaicJumpBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                jump("Layout", $openLayout)
                jump("Opening", $openOpening)
                jump("Toolbars", $openToolbars)
                jump("Focus", $openFocus)
                jump("Motion", $openMotion)
                jump("Dragging", $openDragging)
                jump("Tab strip", $openStrip)
                jump("Borders", $openBorders)
                jump("Background", $openBackground)
            }
            .padding(.vertical, 2)
        }
        .accessibilityLabel("Jump to Mosaic section")
    }

    private func jump(_ title: String, _ expanded: Binding<Bool>) -> some View {
        Button(title) { withAnimation { expanded.wrappedValue = true } }
            .buttonStyle(.bordered)
            .controlSize(.small)
    }

    @ViewBuilder
    private func mosaicCard<Content: View>(_ title: String, expanded: Binding<Bool>, @ViewBuilder content: () -> Content) -> some View {
        Section {
            SettingsDisclosure(title: title, isExpanded: expanded) {
                content()
            }
        }
        .disabled(model.controlsDisabled)
    }

    // MARK: - Groups

    @ViewBuilder private var layoutRows: some View {
        Picker("Most tabs in one Mosaic", selection: Binding(
            get: { model.file.mosaicMaxPanes },
            set: { value in Task { await model.save([ConfigChange("mosaicMaxPanes", .number(Double(value))), ConfigChange("multiViewMaxPanes", nil)]) } }
        )) {
            ForEach(2...PaneLayout.maxPanes, id: \.self) { count in Text("\(count) tabs").tag(count) }
        }
        .settingsMenuValueLabel()
        .help("mosaicMaxPanes in config.json. Every pane is a live page, so each one takes memory and CPU like a tab you're looking at. A Mosaic already bigger stays as it is.")
        Picker("Space between panes", selection: Binding(
            get: { model.file.mosaicGap },
            set: { value in Task { await model.saveKey(.mosaicGap, .number(value)) } }
        )) {
            ForEach(MosaicBar.gaps, id: \.points) { gap in Text(gap.title).tag(gap.points) }
            if !MosaicBar.gaps.contains(where: { $0.points == model.file.mosaicGap }) {
                Text("\(Int(model.file.mosaicGap)) pt").tag(model.file.mosaicGap)
            }
        }
        .settingsMenuValueLabel()
        .help("mosaicGap in config.json, 2 to 16 points. The gap is also where you grab a divider.")
        Stepper(value: Binding(
            get: { model.file.mosaicMinimumPaneWidth },
            set: { value in Task { await model.saveKey(.mosaicMinimumPaneWidth, .number(value)) } }
        ), in: PaddleConfig.mosaicMinimumPaneRange, step: 20) {
            Text("Smallest pane width: \(Int(model.file.mosaicMinimumPaneWidth)) pt")
        }
        .help("mosaicMinimumPaneWidth in config.json.")
        Stepper(value: Binding(
            get: { model.file.mosaicMinimumPaneHeight },
            set: { value in Task { await model.saveKey(.mosaicMinimumPaneHeight, .number(value)) } }
        ), in: PaddleConfig.mosaicMinimumPaneRange, step: 20) {
            Text("Smallest pane height: \(Int(model.file.mosaicMinimumPaneHeight)) pt")
        }
        .help("mosaicMinimumPaneHeight in config.json.")
        SettingsLearnMore(
            summary: "If the window would shrink a pane below these sizes, only the focused pane shows until there is room again.",
            detail: "Freeform Mosaics keep their card sizes; Tidy Up retiles them to the default layout new Mosaics start with, or a grid."
        )
    }

    @ViewBuilder private var motionRows: some View {
        Picker("Animation", selection: Binding(
            get: { model.file.mosaicAnimation },
            set: { value in Task { await model.saveKey(.mosaicAnimation, .string(value.rawValue)) } }
        )) {
            Text("Follow Reduce Motion").tag(MosaicAnimation.system)
            Text("Full").tag(MosaicAnimation.full)
            Text("Reduced (no movement)").tag(MosaicAnimation.reduced)
            Text("Off").tag(MosaicAnimation.off)
        }
        .settingsMenuValueLabel()
        .help("mosaicAnimation in config.json.")
        Picker("Speed", selection: Binding(
            get: { model.file.mosaicAnimationSpeed },
            set: { value in Task { await model.saveKey(.mosaicAnimationSpeed, .string(value.rawValue)) } }
        )) {
            Text("Snappy").tag(MosaicAnimationSpeed.snappy)
            Text("Smooth").tag(MosaicAnimationSpeed.smooth)
            Text("Relaxed").tag(MosaicAnimationSpeed.relaxed)
        }
        .settingsMenuValueLabel()
        .help("mosaicAnimationSpeed in config.json.")
        .disabled(model.file.mosaicAnimation == .off || model.file.mosaicAnimation == .reduced)
        Toggle("Move panes aside while dragging", isOn: Binding(
            get: { model.file.mosaicLiveDragPreview },
            set: { value in Task { await model.saveKey(.mosaicLiveDragPreview, .bool(value)) } }
        ))
        .settingsAccentToggle()
        .help("mosaicLiveDragPreview in config.json.")
        SettingsLearnMore(
            summary: "Full uses a spring; Reduced jumps panes and only fades chrome; Follow Reduce Motion follows macOS or Appearance.",
            detail: "Off shows only a drop highlight while dragging, with no pane movement."
        )
    }

    @ViewBuilder private var bordersRows: some View {
        Picker("Divider grips", selection: Binding(
            get: { model.file.mosaicDividerGrips },
            set: { value in Task { await model.saveKey(.mosaicDividerGrips, .string(value.rawValue)) } }
        )) {
            Text("Always shown").tag(MosaicDividerGrips.always)
            Text("Shown on hover").tag(MosaicDividerGrips.hover)
            Text("Hidden").tag(MosaicDividerGrips.hidden)
        }
        .settingsMenuValueLabel()
        .help("mosaicDividerGrips in config.json. The divider still resizes when its grip is hidden.")
        Toggle("Snap dividers to halves and thirds", isOn: Binding(
            get: { model.file.mosaicDividerSnapping },
            set: { value in Task { await model.saveKey(.mosaicDividerSnapping, .bool(value)) } }
        ))
        .settingsAccentToggle()
        .help("mosaicDividerSnapping in config.json.")
        Picker("Double-clicking a divider", selection: Binding(
            get: { model.file.mosaicDividerDoubleClick },
            set: { value in Task { await model.saveKey(.mosaicDividerDoubleClick, .string(value.rawValue)) } }
        )) {
            Text("Evens out that divider").tag(MosaicDividerDoubleClick.divider)
            Text("Evens out every pane").tag(MosaicDividerDoubleClick.all)
            Text("Does nothing").tag(MosaicDividerDoubleClick.nothing)
        }
        .settingsMenuValueLabel()
        .help("mosaicDividerDoubleClick in config.json.")
        Picker("Pane corners", selection: Binding(
            get: { model.file.mosaicPaneCorners },
            set: { value in Task { await model.saveKey(.mosaicPaneCorners, .string(value.rawValue)) } }
        )) {
            Text("Rounded").tag(MosaicPaneCorners.rounded)
            Text("Square").tag(MosaicPaneCorners.square)
        }
        .settingsMenuValueLabel()
        .help("mosaicPaneCorners in config.json.")
        Picker("Focused pane", selection: Binding(
            get: { model.file.mosaicFocusMarker },
            set: { value in Task { await model.saveKey(.mosaicFocusMarker, .string(value.rawValue)) } }
        )) {
            Text("Has an edge").tag(MosaicFocusMarker.ring)
            Text("Others are dimmed").tag(MosaicFocusMarker.dim)
            Text("Isn't marked").tag(MosaicFocusMarker.none)
        }
        .settingsMenuValueLabel()
        .help("mosaicFocusMarker in config.json.")
        if model.file.mosaicFocusMarker == .dim {
            LabeledContent("Dim the others by") {
                Slider(value: Binding(
                    get: { model.file.mosaicDimAmount },
                    set: { value in Task { await model.saveKey(.mosaicDimAmount, .number((value * 100).rounded() / 100)) } }
                ), in: PaddleConfig.mosaicDimRange)
                .frame(width: 160)
                Text("\(Int((model.file.mosaicDimAmount * 100).rounded())) %").monospacedDigit().frame(width: 40, alignment: .trailing)
            }
            .help("mosaicDimAmount in config.json, 0.05 to 0.7.")
        }
    }

    @ViewBuilder private var toolbarRows: some View {
        Picker("Back, forward, reload and address", selection: Binding(
            get: { model.file.mosaicPaneBars },
            set: { value in Task { await model.saveKey(.mosaicPaneBars, .string(value.rawValue)) } }
        )) {
            Text("Always shown").tag(MosaicPaneBars.always)
            Text("Shown on hover").tag(MosaicPaneBars.hover)
        }
        .settingsMenuValueLabel()
        .help("mosaicPaneBars in config.json.")
        Picker("Size", selection: Binding(
            get: { model.file.mosaicToolbarSize },
            set: { value in Task { await model.saveKey(.mosaicToolbarSize, .string(value.rawValue)) } }
        )) {
            Text("Regular").tag(MosaicToolbarSize.regular)
            Text("Compact").tag(MosaicToolbarSize.compact)
        }
        .settingsMenuValueLabel()
        .help("mosaicToolbarSize in config.json.")
        ForEach(MosaicToolbarButton.allCases, id: \.self) { button in
            Toggle(MosaicPane.title(of: button), isOn: Binding(
                get: { model.file.mosaicToolbarButtons.contains(button) },
                set: { on in
                    var chosen = Set(model.file.mosaicToolbarButtons)
                    if on { chosen.insert(button) } else { chosen.remove(button) }
                    let ordered = MosaicToolbarButton.allCases.filter(chosen.contains).map { JSONValue.string($0.rawValue) }
                    Task { await model.saveKey(.mosaicToolbarButtons, .array(ordered)) }
                }
            ))
            .settingsAccentToggle()
        }
        .help("mosaicToolbarButtons in config.json.")
        SettingsLearnMore(
            summary: "On hover, each pane's toolbar overlays the page; ⌘L focuses the address field.",
            detail: "The site icon (for dragging) and the address field stay visible."
        )
    }

    @ViewBuilder private var draggingRows: some View {
        Picker("Move a pane by its", selection: Binding(
            get: { model.file.mosaicPaneGrab },
            set: { value in Task { await model.saveKey(.mosaicPaneGrab, .string(value.rawValue)) } }
        )) {
            Text("Site icon").tag(MosaicPaneGrab.icon)
            Text("Grip handle").tag(MosaicPaneGrab.grip)
            Text("Whole toolbar").tag(MosaicPaneGrab.toolbar)
        }
        .settingsMenuValueLabel()
        .help("mosaicPaneGrab in config.json. The address field always stays for typing.")
        Toggle("⌥⌘-drag a page to move its pane", isOn: Binding(
            get: { model.file.mosaicModifierDrag },
            set: { value in Task { await model.saveKey(.mosaicModifierDrag, .bool(value)) } }
        ))
        .settingsAccentToggle()
        .help("mosaicModifierDrag in config.json.")
        Toggle("Drag the window by the empty toolbar", isOn: Binding(
            get: { model.file.mosaicWindowDrag },
            set: { value in Task { await model.saveKey(.mosaicWindowDrag, .bool(value)) } }
        ))
        .settingsAccentToggle()
        .help("mosaicWindowDrag in config.json. Double-click follows your system setting (zoom or minimize).")
        SettingsLearnMore(
            summary: "Drop a pane on another pane's edge to split, or on its middle to swap.",
            detail: "The empty middle of the Mosaic toolbar moves the window, like the title bar."
        )
    }

    @ViewBuilder private var openingRows: some View {
        Picker("⌘T while a Mosaic shows", selection: Binding(
            get: { model.file.mosaicNewTab },
            set: { value in Task { await model.saveKey(.mosaicNewTab, .string(value.rawValue)) } }
        )) {
            Text("Opens a tab").tag(MosaicOpening.tab)
            Text("Adds a pane").tag(MosaicOpening.pane)
        }
        .settingsMenuValueLabel()
        .help("mosaicNewTab in config.json. A full Mosaic opens a tab.")
        Picker("Links a pane opens in a new tab", selection: Binding(
            get: { model.file.mosaicLinks },
            set: { value in Task { await model.saveKey(.mosaicLinks, .string(value.rawValue)) } }
        )) {
            Text("Open as tabs").tag(MosaicOpening.tab)
            Text("Open as panes").tag(MosaicOpening.pane)
        }
        .settingsMenuValueLabel()
        .help("mosaicLinks in config.json. ⌘-click, middle-click and target=_blank links; windows a script opens (sign-ins) stay tabs.")
        Picker("A new pane takes half of", selection: Binding(
            get: { model.file.mosaicNewPanePlacement },
            set: { value in Task { await model.saveKey(.mosaicNewPanePlacement, .string(value.rawValue)) } }
        )) {
            Text("The largest pane").tag(PanePlacement.largest)
            Text("The focused pane").tag(PanePlacement.focused)
            Text("The last pane").tag(PanePlacement.last)
        }
        .settingsMenuValueLabel()
        .help("mosaicNewPanePlacement in config.json.")
        Picker("New Mosaics start as", selection: Binding(
            get: { model.file.mosaicDefaultLayout },
            set: { value in Task { await model.saveKey(.mosaicDefaultLayout, .string(value.rawValue)) } }
        )) {
            Text("Wherever you drop").tag(MosaicDefaultLayout.asDropped)
            Text("Columns").tag(MosaicDefaultLayout.columns)
            Text("Rows").tag(MosaicDefaultLayout.rows)
            Text("Grid").tag(MosaicDefaultLayout.grid)
            Text("Main and Stack").tag(MosaicDefaultLayout.mainAndStack)
        }
        .settingsMenuValueLabel()
        .help("mosaicDefaultLayout in config.json.")
        Toggle("Re-tile when panes join or leave", isOn: Binding(
            get: { model.file.mosaicAutoArrange },
            set: { value in Task { await model.saveKey(.mosaicAutoArrange, .bool(value)) } }
        ))
        .settingsAccentToggle()
        .help("mosaicAutoArrange in config.json. Uses the layout above.")
        .disabled(model.file.mosaicDefaultLayout == .asDropped)
    }

    @ViewBuilder private var focusRows: some View {
        Picker("⇧⌘D (Dark Mode) in a Mosaic", selection: Binding(
            get: { model.file.mosaicDarkMode },
            set: { value in Task { await model.saveKey(.mosaicDarkMode, .string(value.rawValue)) } }
        )) {
            Text("Switches the focused pane's site").tag(MosaicDarkMode.site)
            Text("Switches every pane together").tag(MosaicDarkMode.unified)
            Text("Switches the focused pane only").tag(MosaicDarkMode.perPane)
        }
        .settingsMenuValueLabel()
        .help("mosaicDarkMode in config.json. Unified and per pane aren't saved; right-click a pane's toolbar to set one pane.")
        Picker("Zoom (⌘+ ⌘− ⌘0) changes", selection: Binding(
            get: { model.file.mosaicZoom },
            set: { value in Task { await model.saveKey(.mosaicZoom, .string(value.rawValue)) } }
        )) {
            Text("The focused pane").tag(MosaicZoom.focused)
            Text("Every pane").tag(MosaicZoom.all)
        }
        .settingsMenuValueLabel()
        .help("mosaicZoom in config.json.")
        Toggle("Focus the pane under the pointer", isOn: Binding(
            get: { model.file.mosaicFocusFollowsPointer },
            set: { value in Task { await model.saveKey(.mosaicFocusFollowsPointer, .bool(value)) } }
        ))
        .settingsAccentToggle()
        .help("mosaicFocusFollowsPointer in config.json. After the pointer rests on it for a moment; never while you type in an address.")
        Picker("Sound plays from", selection: Binding(
            get: { model.file.mosaicSound },
            set: { value in Task { await model.saveKey(.mosaicSound, .string(value.rawValue)) } }
        )) {
            Text("Every pane").tag(MosaicSound.all)
            Text("The focused pane only").tag(MosaicSound.focused)
        }
        .settingsMenuValueLabel()
        .help("mosaicSound in config.json. The other panes are muted while unfocused; muting or unmuting one yourself takes it out of this.")
        Picker("⌘W in a pane", selection: Binding(
            get: { model.file.mosaicCloseKey },
            set: { value in Task { await model.saveKey(.mosaicCloseKey, .string(value.rawValue)) } }
        )) {
            Text("Closes the tab").tag(MosaicCloseKey.closeTab)
            Text("Takes it out of the Mosaic").tag(MosaicCloseKey.removePane)
        }
        .settingsMenuValueLabel()
        .help("mosaicCloseKey in config.json.")
        SettingsCaption("Right-click a pane's toolbar to turn dark mode on or off for that pane alone.")
    }

    @ViewBuilder private var stripRows: some View {
        Picker("A Mosaic's item shows", selection: Binding(
            get: { model.file.mosaicStripIcon },
            set: { value in Task { await model.saveKey(.mosaicStripIcon, .string(value.rawValue)) } }
        )) {
            Text("Its icon").tag(MosaicStripIcon.icon)
            Text("Its panes' site icons").tag(MosaicStripIcon.favicons)
        }
        .settingsMenuValueLabel()
        .help("mosaicStripIcon in config.json.")
        Picker("An unnamed Mosaic is called by", selection: Binding(
            get: { model.file.mosaicStripName },
            set: { value in Task { await model.saveKey(.mosaicStripName, .string(value.rawValue)) } }
        )) {
            Text("The focused pane's site").tag(MosaicStripName.focused)
            Text("Every pane's site").tag(MosaicStripName.all)
        }
        .settingsMenuValueLabel()
        .help("mosaicStripName in config.json. Rename Mosaic… gives it a name of its own.")
        Toggle("Shade Mosaic items so they stand out from tabs", isOn: Binding(
            get: { model.file.mosaicStripShading },
            set: { value in Task { await model.saveKey(.mosaicStripShading, .bool(value)) } }
        ))
        .settingsAccentToggle()
        .help("mosaicStripShading in config.json.")
        if model.file.mosaicStripShading {
            MosaicShadingRows(model: model)
        }
    }

    @ViewBuilder private var backgroundRows: some View {
        Toggle("Keep the last Mosaic ready", isOn: Binding(
            get: { model.file.mosaicStaysReady },
            set: { value in Task { await model.saveKey(.mosaicStaysReady, .bool(value)) } }
        ))
        .settingsAccentToggle()
        .help("mosaicStaysReady in config.json.")
        SettingsLearnMore(
            summary: "On, every pane stays attached when you leave the Mosaic so return is instant.",
            detail: "Off keeps only the focused pane attached, saving a little CPU. Some sites refresh when hidden."
        )
        MosaicTimerPicker(model: model, key: .mosaicFreezeAfterMinutes, title: "Freeze a Mosaic after",
                          tabValue: model.file.tabFreezeAfterMinutes, value: model.file.mosaicFreezeAfterMinutes)
        MosaicTimerPicker(model: model, key: .mosaicSleepAfterMinutes, title: "Put a Mosaic to sleep after",
                          tabValue: model.file.tabSleepAfterMinutes, value: model.file.mosaicSleepAfterMinutes)
        SettingsLearnMore(
            summary: "A background Mosaic freezes and sleeps as one unit, timed from the last pane you used.",
            detail: "Sound, uploads, unsaved changes or notify permission keeps the whole Mosaic awake."
        )
    }
}

extension MosaicPane {
    static func title(of button: MosaicToolbarButton) -> String {
        switch button {
        case .back: "Show Back"
        case .forward: "Show Forward"
        case .reload: "Show Reload"
        case .close: "Show × (Remove from Mosaic)"
        }
    }
}

/// A Mosaic timer: Same as tabs (the key left out), Never (0), or minutes.
private struct MosaicTimerPicker: View {
    let model: SettingsModel
    let key: PaddleConfig.CodingKeys
    let title: String
    let tabValue: Double
    let value: Double?

    private static let sameAsTabs: Double = -1
    private static let choices: [Double] = [0, 1, 2, 5, 10, 15, 30, 60, 120, 240]

    var body: some View {
        Picker(title, selection: Binding(
            get: { value ?? Self.sameAsTabs },
            set: { chosen in
                Task {
                    await model.save([ConfigChange(key.rawValue, chosen == Self.sameAsTabs ? nil : .number(chosen))])
                }
            }
        )) {
            Text("Same as tabs (\(Self.label(tabValue)))").tag(Self.sameAsTabs)
            Divider()
            ForEach(Array(Set(Self.choices + [value ?? 0])).sorted(), id: \.self) { minutes in
                Text(Self.label(minutes)).tag(minutes)
            }
        }
        .settingsMenuValueLabel()
        .help("\(key.rawValue) in config.json: left out follows the tab setting, 0 = never.")
    }

    private static func label(_ minutes: Double) -> String {
        if minutes == 0 { return "Never" }
        if minutes >= 60, minutes.truncatingRemainder(dividingBy: 60) == 0 {
            let hours = Int(minutes / 60)
            return "\(hours) hour\(hours == 1 ? "" : "s")"
        }
        return "\(minutes.formatted()) minute\(minutes == 1 ? "" : "s")"
    }
}

/// The shading's color, strength and style, with a preview of a Mosaic item next to a tab.
private struct MosaicShadingRows: View {
    let model: SettingsModel
    @State private var custom = Color.orange

    private static let custom = "custom"
    private var color: String { model.file.mosaicStripColor }
    private var isCustom: Bool { color.hasPrefix("#") }

    var body: some View {
        Picker("Color", selection: Binding(
            get: { isCustom ? Self.custom : color },
            set: { value in
                let saved = value == Self.custom ? "#" + ThemeColorHex.hex(of: custom) : value
                Task { await model.saveKey(.mosaicStripColor, .string(saved)) }
            }
        )) {
            Text("Accent color").tag("accent")
            Text("The Mosaic's icon tint").tag("icon")
            Divider()
            ForEach(ColorPreset.allCases, id: \.self) { preset in Text(preset.displayName).tag(preset.rawValue) }
            Divider()
            Text("Custom").tag(Self.custom)
        }
        .settingsMenuValueLabel()
        .help("mosaicStripColor in config.json: accent, icon, a color name or #rrggbb. Icon tint falls back to the accent for a Mosaic without one.")
        if isCustom {
            ColorPicker("Custom color", selection: Binding(
                get: { RGBColor(hex: color).map { Color(rgb: $0) } ?? custom },
                set: { value in
                    custom = value
                    Task { await model.saveKey(.mosaicStripColor, .string("#" + ThemeColorHex.hex(of: value))) }
                }
            ), supportsOpacity: false)
        }
        LabeledContent("Strength") {
            Slider(value: Binding(
                get: { model.file.mosaicStripStrength },
                set: { value in Task { await model.saveKey(.mosaicStripStrength, .number(value.rounded())) } }
            ), in: PaddleConfig.mosaicStripStrengthRange)
            .frame(width: 160)
            Text("\(Int(model.file.mosaicStripStrength)) %").monospacedDigit().frame(width: 40, alignment: .trailing)
        }
        .help("mosaicStripStrength in config.json, 4 to 60.")
        Picker("Style", selection: Binding(
            get: { model.file.mosaicStripStyle },
            set: { value in Task { await model.saveKey(.mosaicStripStyle, .string(value.rawValue)) } }
        )) {
            Text("Fill and outline").tag(MosaicStripStyle.both)
            Text("Fill").tag(MosaicStripStyle.fill)
            Text("Outline").tag(MosaicStripStyle.outline)
        }
        .settingsMenuValueLabel()
        .help("mosaicStripStyle in config.json.")
        LabeledContent("Preview") {
            HStack(spacing: 6) {
                preview(title: "A tab", shaded: false)
                preview(title: "A Mosaic", shaded: true)
            }
        }
        SettingsCaption("The outline is drawn stronger than the fill, so a Mosaic stands out by its brightness and edge as well as its color.")
    }

    private func preview(title: String, shaded: Bool) -> some View {
        let shade = MosaicStripShade.color(color, layout: PaneLayout("a", "b")!, accent: .accentColor)
        let strength = model.file.mosaicStripStrength / 100
        let style = model.file.mosaicStripStyle
        let shape = RoundedRectangle(cornerRadius: 7)
        return Text(title)
            .font(.caption)
            .padding(.horizontal, 10)
            .frame(width: 90, height: 24)
            .background(shape.fill(shaded && style != .outline ? shade.opacity(strength) : Color.primary.opacity(0.06)))
            .overlay(shape.strokeBorder(shaded && style != .fill ? shade.opacity(min(1, strength * 3 + 0.15)) : .clear, lineWidth: 1.5))
    }
}

/// `#rrggbb` text for a color (no leading #).
enum ThemeColorHex {
    static func hex(of color: Color) -> String {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return "ff8800" }
        func part(_ v: CGFloat) -> String { String(format: "%02x", Int((min(max(v, 0), 1) * 255).rounded())) }
        return part(c.redComponent) + part(c.greenComponent) + part(c.blueComponent)
    }
}
