import PaddleCore
import AppKit
import SwiftUI

/// Settings > Appearance: light/dark, tab layout, chrome text size, page zoom, minimum font size,
/// accessibility.
struct AppearancePane: View {
    let model: SettingsModel
    @Environment(\.colorScheme) private var colorScheme
    /// The tint strength while the slider is dragged; saved when the drag ends.
    @State private var strengthDraft: Double?
    @State private var appearanceDraft: AppearanceMode?
    @State private var showingThemeBuilder = false
    @State private var editingTheme: ChromeTheme?

    /// Default zoom choices (percent); a value set by hand is added to them.
    private static let zoomLevels = [50, 67, 75, 80, 90, 100, 110, 125, 150, 175, 200]
    /// Minimum font sizes (points); 0 is off.
    private static let fontSizes = [0, 9, 10, 11, 12, 14, 16, 18, 20, 24]

    var body: some View {
        SettingsForm {
            themeSection
            Section("Windows") {
                Picker("Appearance", selection: Binding(
                    get: { appearanceDraft ?? model.file.appearance },
                    set: { value in
                        appearanceDraft = value
                        AppModel.shared.applyAppearance(value)
                        Task {
                            await model.saveKey(.appearance, .string(value.rawValue))
                            if model.file.appearance == value {
                                appearanceDraft = nil
                            }
                        }
                    }
                )) {
                    Text("System").tag(AppearanceMode.system)
                    Text("Light").tag(AppearanceMode.light)
                    Text("Dark").tag(AppearanceMode.dark)
                }
                .pickerStyle(.segmented)
                .transaction { $0.animation = nil }
                .help("appearance in config.json. System follows macOS; pages follow the window.")
                Picker("Tab layout", selection: Binding(
                    get: { model.file.tabLayout },
                    set: { value in Task { await model.saveKey(.tabLayout, .string(value.rawValue)) } }
                )) {
                    Text("Horizontal").tag(TabLayout.horizontal)
                    Text("Vertical").tag(TabLayout.vertical)
                }
                .help("tabLayout in config.json, View > Vertical Tabs. Vertical shows the tabs in a sidebar.")
                Picker("Text size", selection: Binding(
                    get: { model.file.interfaceTextSize },
                    set: { value in Task { await model.saveKey(.interfaceTextSize, .string(value.rawValue)) } }
                )) {
                    Text("Small").tag(InterfaceTextSize.small)
                    Text("Default").tag(InterfaceTextSize.default)
                    Text("Large").tag(InterfaceTextSize.large)
                    Text("Larger").tag(InterfaceTextSize.larger)
                }
                .help("interfaceTextSize in config.json. The size of Paddle's own text: tabs, toolbar and bars. Pages are not affected.")
                Toggle("High-contrast selected tab", isOn: Binding(
                    get: { model.file.highContrastTabs },
                    set: { value in Task { await model.saveKey(.highContrastTabs, .bool(value)) } }
                ))
                .help("highContrastTabs in config.json. Draws the selected tab with a stronger outline and brightness difference.")
            }
            .disabled(model.controlsDisabled)
            Section("Toolbar & Tabs") {
                Toggle("Show Home button on toolbar", isOn: Binding(
                    get: { model.file.showHomeButton },
                    set: { value in Task { await model.saveKey(.showHomeButton, .bool(value)) } }
                ))
                .help("showHomeButton in config.json. Adds a Home button that navigates directly to your homepage.")
                Toggle("Always show Downloads button", isOn: Binding(
                    get: { model.file.alwaysShowDownloadsButton },
                    set: { value in Task { await model.saveKey(.alwaysShowDownloadsButton, .bool(value)) } }
                ))
                .help("alwaysShowDownloadsButton in config.json. Keeps the Downloads icon visible even when no downloads are active.")
                Toggle("Always show tab close buttons", isOn: Binding(
                    get: { model.file.alwaysShowTabCloseButtons },
                    set: { value in Task { await model.saveKey(.alwaysShowTabCloseButtons, .bool(value)) } }
                ))
                .help("alwaysShowTabCloseButtons in config.json. Keeps the close button visible on all tabs without having to hover.")
            }
            .disabled(model.controlsDisabled)
            Section("Pages") {
                Picker("Website dark mode", selection: Binding(
                    get: { model.file.darkMode },
                    set: { value in Task { await model.saveKey(.darkMode, .string(value.rawValue)) } }
                )) {
                    Text("Off").tag(DarkModePreference.off)
                    Text("System").tag(DarkModePreference.system)
                    Text("Smart").tag(DarkModePreference.smart)
                    Text("Native").tag(DarkModePreference.native)
                }
                .pickerStyle(.segmented)
                .help("darkMode in config.json. Smart is the recommendation: inverts bright pages and skips sites that are already dark. Native only sets color-scheme and never inverts. System follows the window appearance. Off leaves sites alone. A per-site setting in Settings > Sites still wins.")
                Toggle("Invert bright text images in dark mode", isOn: Binding(
                    get: { model.file.invertTextImages },
                    set: { value in Task { await model.saveKey(.invertTextImages, .bool(value)) } }
                ))
                .help("invertTextImages in config.json. Inverts screenshots of text and documents on bright backgrounds when dark mode is active. Option-click any image to toggle.")
                zoomPicker
                fontSizePicker
            }
            .disabled(model.controlsDisabled)
            Section("Accessibility") {
                Toggle("Underline website links", isOn: Binding(
                    get: { model.file.underlineLinks },
                    set: { value in Task { await model.saveKey(.underlineLinks, .bool(value)) } }
                ))
                .help("underlineLinks in config.json. Underlines links on web pages for colorblind accessibility.")
                Toggle("Always reduce motion", isOn: Binding(
                    get: { model.file.reduceMotion == .always },
                    set: { value in Task { await model.saveKey(.reduceMotion, .string(value ? "always" : "system")) } }
                ))
                .help("reduceMotion in config.json. Off follows System Settings > Accessibility > Display.")
                Toggle("Always reduce transparency", isOn: Binding(
                    get: { model.file.reduceTransparency == .always },
                    set: { value in Task { await model.saveKey(.reduceTransparency, .string(value ? "always" : "system")) } }
                ))
                .help("reduceTransparency in config.json. Off follows System Settings > Accessibility > Display.")
            }
            .disabled(model.controlsDisabled)
        }
        .sheet(isPresented: $showingThemeBuilder) {
            ThemeBuilderSheet(model: model, existingTheme: editingTheme) {
                showingThemeBuilder = false
            }
        }
    }

    // MARK: - Theme

    private var createThemeButton: some View {
        Button("Create Custom Theme…") {
            editingTheme = nil
            showingThemeBuilder = true
        }
    }

    /// Edit and Delete, for a custom theme only.
    @ViewBuilder private var customThemeButtons: some View {
        if let current = AppModel.shared.themes.available.first(where: { $0.id == model.file.theme }), !current.isBuiltIn {
            Button("Edit Theme…") {
                editingTheme = current
                showingThemeBuilder = true
            }
            Button("Delete Theme", role: .destructive) {
                deleteCustomTheme(id: current.id)
            }
        }
    }

    private var openThemesFolderButton: some View {
        Button("Open Themes Folder") {
            try? FileManager.default.createDirectory(at: Paths.themes, withIntermediateDirectories: true)
            NSWorkspace.shared.open(Paths.themes)
        }
    }

    private var themeSection: some View {
        let app = AppModel.shared
        return Section("Theme") {
            Picker("Theme", selection: Binding(
                get: { model.file.theme },
                set: { value in Task { await model.saveKey(.theme, .string(value)) } }
            )) {
                Text("Default").tag("default")
                ForEach(app.themes.available) { Text($0.name).tag($0.id) }
                if model.file.theme != "default", !app.themes.available.contains(where: { $0.id == model.file.theme }) {
                    Text("\(model.file.theme) (not found)").tag(model.file.theme)
                }
            }
            .help("theme in config.json. Default keeps today's look; the others set the colors of the tab strip, toolbar, selected tab, text and New Tab page.")
            // On one line when the card is wide enough, else the custom theme's Edit and Delete on a second line.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    createThemeButton
                    customThemeButtons
                    openThemesFolderButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        createThemeButton
                        openThemesFolderButton
                    }
                    HStack(spacing: 12) { customThemeButtons }
                }
            }
            .help("themes/ in the config folder. Create, customize, or open themes/<name>.json files.")
            // Every theme problem, not only the first one the notice under the toolbar names.
            ForEach(app.themeWarnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            colorPicker(
                "Accent", key: .accentColor, value: model.file.accentColor, automatic: ("system", "System"),
                help: "accentColor in config.json. Overrides the theme's accent: progress bar, focus rings and the chrome's controls."
            )
            colorPicker(
                "Tint", key: .chromeTint, value: model.file.chromeTint, automatic: ("none", "None"),
                help: "chromeTint in config.json. A color blended over the tab strip and toolbar."
            )
            let tintOff = ColorChoice(configValue: model.file.chromeTint, automaticValue: "none").map { $0 == .automatic } ?? true
            HStack {
                Slider(
                    value: Binding(
                        get: { strengthDraft ?? model.file.chromeTintStrength },
                        set: { strengthDraft = $0.rounded() }
                    ),
                    in: 0...100,
                    onEditingChanged: { editing in
                        guard !editing, let value = strengthDraft else { return }
                        Task {
                            await model.saveKey(.chromeTintStrength, .number(value))
                            strengthDraft = nil
                        }
                    }
                ) { Text("Tint strength") }
                Text("\(Int(strengthDraft ?? model.file.chromeTintStrength)) %").monospacedDigit().frame(width: 48, alignment: .trailing)
            }
            .disabled(tintOff)
            .help("chromeTintStrength in config.json, 0 to 100. How much of the tint is blended in.")
            let capped = Int((app.effectiveTintStrength(dark: colorScheme == .dark) * 100).rounded())
            if !tintOff, capped < Int(model.file.chromeTintStrength.rounded()) {
                Text("Capped at \(capped) % so text stays readable.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(model.controlsDisabled)
    }

    /// A picker of "automatic", the eight preset names and Custom, with a color well for Custom.
    private func colorPicker(
        _ title: String, key: PaddleConfig.CodingKeys, value: String, automatic: (value: String, label: String), help: String
    ) -> some View {
        let choice = ColorChoice(configValue: value, automaticValue: automatic.value) ?? .automatic
        let tag: String = switch choice {
        case .automatic: "automatic"
        case .preset(let preset): preset.rawValue
        case .custom: "custom"
        }
        return HStack {
            Picker(title, selection: Binding(
                get: { tag },
                set: { new in
                    let next: ColorChoice
                    if new == "automatic" {
                        next = .automatic
                    } else if let preset = ColorPreset(rawValue: new) {
                        next = .preset(preset)
                    } else {
                        next = .custom(choice.color ?? ColorPreset.blue.color)
                    }
                    Task { await model.saveKey(key, .string(next.configValue(automaticValue: automatic.value))) }
                }
            )) {
                Text(automatic.label).tag("automatic")
                ForEach(ColorPreset.allCases, id: \.self) { Text($0.displayName).tag($0.rawValue) }
                Text("Custom").tag("custom")
            }
            if case .custom(let color) = choice {
                CustomColorWell(title: title, saved: color) { hex in
                    Task { await model.saveKey(key, .string(hex)) }
                }
            }
        }
        .help(help)
    }

    private var zoomPicker: some View {
        let current = Int((model.file.defaultZoom * 100).rounded())
        let levels = Self.zoomLevels.contains(current) ? Self.zoomLevels : (Self.zoomLevels + [current]).sorted()
        return Picker("Default zoom", selection: Binding(
            get: { current },
            set: { percent in Task { await model.saveKey(.defaultZoom, .number(SitePolicy.normalizedZoom(Double(percent) / 100))) } }
        )) {
            ForEach(levels, id: \.self) { Text("\($0) %").tag($0) }
        }
        .help("defaultZoom in config.json. The zoom of sites with none of their own (Settings > Sites); View > Actual Size returns a page to it.")
    }

    private var fontSizePicker: some View {
        let current = Int(model.file.minimumFontSize.rounded())
        let sizes = Self.fontSizes.contains(current) ? Self.fontSizes : (Self.fontSizes + [current]).sorted()
        return Picker("Minimum font size", selection: Binding(
            get: { current },
            set: { size in Task { await model.saveKey(.minimumFontSize, .number(Double(size))) } }
        )) {
            ForEach(sizes, id: \.self) { Text($0 == 0 ? "Off" : "\($0) pt").tag($0) }
        }
        .help("minimumFontSize in config.json. Pages never show text smaller than this; Off leaves the page's sizes alone.")
    }

    private func deleteCustomTheme(id: String) {
        let file = Paths.themes.appendingPathComponent("\(id).json")
        try? FileManager.default.removeItem(at: file)
        AppModel.shared.themes.load()
        Task {
            await model.saveKey(.theme, .string("default"))
        }
    }
}

/// The color well for a Custom accent or tint. Dragging in the color panel sends a change for every step, so the
/// well shows a draft and writes config.json once the color has held for 0.4 s.
struct CustomColorWell: View {
    let title: String
    let saved: PaddleCore.RGBColor
    let save: (String) -> Void
    @State private var draft: PaddleCore.RGBColor?

    var body: some View {
        let shown = draft ?? saved
        ColorPicker(title, selection: Binding(
            get: { Color(.sRGB, red: shown.red, green: shown.green, blue: shown.blue) },
            set: { new in
                guard let c = NSColor(new).usingColorSpace(.sRGB) else { return }
                draft = PaddleCore.RGBColor(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent)
            }
        ), supportsOpacity: false)
        .labelsHidden()
        Text(shown.hex).monospaced().foregroundStyle(.secondary)
            .task(id: draft) {
                guard let draft, draft != saved else { return }
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                save(draft.hex.lowercased())
            }
    }
}
