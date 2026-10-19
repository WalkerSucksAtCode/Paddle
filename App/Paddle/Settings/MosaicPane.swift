import PaddleCore
import SwiftUI

/// Settings > Mosaic: how a Mosaic is laid out, its panes' toolbars, and how it behaves while you're on another tab
/// (its own freeze and sleep timers, which it follows as one, and whether it stays ready for an instant return).
struct MosaicPane: View {
    let model: SettingsModel

    var body: some View {
        SettingsForm {
            Section("Layout") {
                Picker("Most tabs in one Mosaic", selection: Binding(
                    get: { model.file.mosaicMaxPanes },
                    set: { value in Task { await model.save([ConfigChange("mosaicMaxPanes", .number(Double(value))), ConfigChange("multiViewMaxPanes", nil)]) } }
                )) {
                    ForEach(2...PaneLayout.maxPanes, id: \.self) { count in Text("\(count) tabs").tag(count) }
                }
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
                SettingsCaption("When the window would make any pane smaller than this, the Mosaic shows only its focused pane until there is room again.")
            }
            .disabled(model.controlsDisabled)

            Section("Motion") {
                Picker("Animation", selection: Binding(
                    get: { model.file.mosaicAnimation },
                    set: { value in Task { await model.saveKey(.mosaicAnimation, .string(value.rawValue)) } }
                )) {
                    Text("Follow Reduce Motion").tag(MosaicAnimation.system)
                    Text("Full").tag(MosaicAnimation.full)
                    Text("Reduced (no movement)").tag(MosaicAnimation.reduced)
                    Text("Off").tag(MosaicAnimation.off)
                }
                .help("mosaicAnimation in config.json.")
                Picker("Speed", selection: Binding(
                    get: { model.file.mosaicAnimationSpeed },
                    set: { value in Task { await model.saveKey(.mosaicAnimationSpeed, .string(value.rawValue)) } }
                )) {
                    Text("Snappy").tag(MosaicAnimationSpeed.snappy)
                    Text("Smooth").tag(MosaicAnimationSpeed.smooth)
                    Text("Relaxed").tag(MosaicAnimationSpeed.relaxed)
                }
                .help("mosaicAnimationSpeed in config.json.")
                .disabled(model.file.mosaicAnimation == .off || model.file.mosaicAnimation == .reduced)
                Toggle("Move panes aside while dragging", isOn: Binding(
                    get: { model.file.mosaicLiveDragPreview },
                    set: { value in Task { await model.saveKey(.mosaicLiveDragPreview, .bool(value)) } }
                ))
                .help("mosaicLiveDragPreview in config.json.")
                SettingsCaption("Full animates layout changes with a spring. Reduced moves nothing: panes jump to their new places and only toolbars and highlights fade. Follow Reduce Motion is Full, or Reduced while macOS's Reduce Motion (or Settings > Appearance) is on. Off, while dragging, only a highlight shows where a tab will land.")
            }
            .disabled(model.controlsDisabled)

            Section("Borders and look") {
                Picker("Divider grips", selection: Binding(
                    get: { model.file.mosaicDividerGrips },
                    set: { value in Task { await model.saveKey(.mosaicDividerGrips, .string(value.rawValue)) } }
                )) {
                    Text("Always shown").tag(MosaicDividerGrips.always)
                    Text("Shown on hover").tag(MosaicDividerGrips.hover)
                    Text("Hidden").tag(MosaicDividerGrips.hidden)
                }
                .help("mosaicDividerGrips in config.json. The divider still resizes when its grip is hidden.")
                Toggle("Snap dividers to halves and thirds", isOn: Binding(
                    get: { model.file.mosaicDividerSnapping },
                    set: { value in Task { await model.saveKey(.mosaicDividerSnapping, .bool(value)) } }
                ))
                .help("mosaicDividerSnapping in config.json.")
                Picker("Double-clicking a divider", selection: Binding(
                    get: { model.file.mosaicDividerDoubleClick },
                    set: { value in Task { await model.saveKey(.mosaicDividerDoubleClick, .string(value.rawValue)) } }
                )) {
                    Text("Evens out that divider").tag(MosaicDividerDoubleClick.divider)
                    Text("Evens out every pane").tag(MosaicDividerDoubleClick.all)
                    Text("Does nothing").tag(MosaicDividerDoubleClick.nothing)
                }
                .help("mosaicDividerDoubleClick in config.json.")
                Picker("Pane corners", selection: Binding(
                    get: { model.file.mosaicPaneCorners },
                    set: { value in Task { await model.saveKey(.mosaicPaneCorners, .string(value.rawValue)) } }
                )) {
                    Text("Rounded").tag(MosaicPaneCorners.rounded)
                    Text("Square").tag(MosaicPaneCorners.square)
                }
                .help("mosaicPaneCorners in config.json.")
                Picker("Focused pane", selection: Binding(
                    get: { model.file.mosaicFocusMarker },
                    set: { value in Task { await model.saveKey(.mosaicFocusMarker, .string(value.rawValue)) } }
                )) {
                    Text("Has an edge").tag(MosaicFocusMarker.ring)
                    Text("Others are dimmed").tag(MosaicFocusMarker.dim)
                    Text("Isn't marked").tag(MosaicFocusMarker.none)
                }
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
            .disabled(model.controlsDisabled)

            Section("Pane toolbars") {
                Picker("Back, forward, reload and address", selection: Binding(
                    get: { model.file.mosaicPaneBars },
                    set: { value in Task { await model.saveKey(.mosaicPaneBars, .string(value.rawValue)) } }
                )) {
                    Text("Always shown").tag(MosaicPaneBars.always)
                    Text("Shown on hover").tag(MosaicPaneBars.hover)
                }
                .help("mosaicPaneBars in config.json.")
                Picker("Size", selection: Binding(
                    get: { model.file.mosaicToolbarSize },
                    set: { value in Task { await model.saveKey(.mosaicToolbarSize, .string(value.rawValue)) } }
                )) {
                    Text("Regular").tag(MosaicToolbarSize.regular)
                    Text("Compact").tag(MosaicToolbarSize.compact)
                }
                .help("mosaicToolbarSize in config.json.")
                ForEach(MosaicToolbarButton.allCases, id: \.self) { button in
                    Toggle(Self.title(of: button), isOn: Binding(
                        get: { model.file.mosaicToolbarButtons.contains(button) },
                        set: { on in
                            var chosen = Set(model.file.mosaicToolbarButtons)
                            if on { chosen.insert(button) } else { chosen.remove(button) }
                            let ordered = MosaicToolbarButton.allCases.filter(chosen.contains).map { JSONValue.string($0.rawValue) }
                            Task { await model.saveKey(.mosaicToolbarButtons, .array(ordered)) }
                        }
                    ))
                }
                .help("mosaicToolbarButtons in config.json.")
                SettingsCaption("On hover, each pane's toolbar shows over the top of its page while the pointer is in the pane; ⌘L shows the focused one's. The site icon (drag it to move the pane) and the address field are always there.")
            }
            .disabled(model.controlsDisabled)

            Section("In the background") {
                Toggle("Keep the last Mosaic ready", isOn: Binding(
                    get: { model.file.mosaicStaysReady },
                    set: { value in Task { await model.saveKey(.mosaicStaysReady, .bool(value)) } }
                ))
                .help("mosaicStaysReady in config.json.")
                SettingsCaption("On, every page of the Mosaic you just left stays attached, so going back is instant and no page is told it was hidden (some sites, like X, refresh when they are). Off, only its focused pane stays attached, which saves a little CPU.")
                MosaicTimerPicker(model: model, key: .mosaicFreezeAfterMinutes, title: "Freeze a Mosaic after",
                                  tabValue: model.file.tabFreezeAfterMinutes, value: model.file.mosaicFreezeAfterMinutes)
                MosaicTimerPicker(model: model, key: .mosaicSleepAfterMinutes, title: "Put a Mosaic to sleep after",
                                  tabValue: model.file.tabSleepAfterMinutes, value: model.file.mosaicSleepAfterMinutes)
                SettingsCaption("A Mosaic you aren't looking at freezes and sleeps as one: when one pane would, all of them do, timed from the last pane you used. A pane that plays sound, uploads, has unsaved changes or can notify you keeps the whole Mosaic awake.")
            }
            .disabled(model.controlsDisabled)
        }
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
    /// The tab timer it follows when unset.
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
