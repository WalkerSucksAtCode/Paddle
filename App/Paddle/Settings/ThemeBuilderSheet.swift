import AppKit
import PaddleCore
import SwiftUI

/// Visual theme builder sheet: custom color pickers for tab strip, toolbar, selected tab, text, accent,
/// and new tab background for both light and dark appearances, complete with live window preview and
/// WCAG contrast verification.
struct ThemeBuilderSheet: View {
    let model: SettingsModel
    let existingTheme: ChromeTheme?
    let onDismiss: () -> Void

    @State private var themeName: String
    @State private var activeMode: ThemeMode = .light
    @State private var lightPalette: EditablePalette
    @State private var darkPalette: EditablePalette
    @State private var errorMessage: String?

    enum ThemeMode: String, CaseIterable {
        case light = "Light Mode"
        case dark = "Dark Mode"
    }

    struct EditablePalette {
        var tabStrip: Color
        var toolbar: Color
        var selectedTab: Color
        var text: Color
        var secondaryText: Color
        var accent: Color
        var newTabBackground: Color

        init(from palette: ThemePalette?, defaultDark: Bool) {
            let base = defaultDark ? BuiltInThemes.all[0].dark! : BuiltInThemes.all[0].light!
            self.tabStrip = Self.toColor(palette?.tabStrip ?? base.tabStrip ?? .white)
            self.toolbar = Self.toColor(palette?.toolbar ?? base.toolbar ?? .white)
            self.selectedTab = Self.toColor(palette?.selectedTab ?? base.selectedTab ?? .white)
            self.text = Self.toColor(palette?.text ?? base.text ?? .black)
            self.secondaryText = Self.toColor(palette?.secondaryText ?? base.secondaryText ?? .black)
            self.accent = Self.toColor(palette?.accent ?? base.accent ?? PaddleCore.RGBColor(hex: "#007AFF")!)
            self.newTabBackground = Self.toColor(palette?.newTabBackground ?? base.newTabBackground ?? .white)
        }

        func toThemePalette() -> ThemePalette {
            ThemePalette(
                tabStrip: Self.toRGBColor(tabStrip),
                toolbar: Self.toRGBColor(toolbar),
                selectedTab: Self.toRGBColor(selectedTab),
                text: Self.toRGBColor(text),
                secondaryText: Self.toRGBColor(secondaryText),
                accent: Self.toRGBColor(accent),
                newTabBackground: Self.toRGBColor(newTabBackground)
            )
        }

        static func toColor(_ rgb: PaddleCore.RGBColor) -> Color {
            Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1.0)
        }

        static func toRGBColor(_ color: Color) -> PaddleCore.RGBColor {
            guard let c = NSColor(color).usingColorSpace(.sRGB) else { return .black }
            return PaddleCore.RGBColor(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent)
        }
    }

    init(model: SettingsModel, existingTheme: ChromeTheme? = nil, onDismiss: @escaping () -> Void) {
        self.model = model
        self.existingTheme = existingTheme
        self.onDismiss = onDismiss
        _themeName = State(initialValue: existingTheme?.name ?? "")
        _lightPalette = State(initialValue: EditablePalette(from: existingTheme?.light, defaultDark: false))
        _darkPalette = State(initialValue: EditablePalette(from: existingTheme?.dark, defaultDark: true))
    }

    private var currentPaletteBinding: Binding<EditablePalette> {
        activeMode == .light ? $lightPalette : $darkPalette
    }

    private var currentThemePalette: ThemePalette {
        activeMode == .light ? lightPalette.toThemePalette() : darkPalette.toThemePalette()
    }

    private var contrastIssues: [String] {
        ThemeContrast.issues(currentThemePalette, highContrast: false)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    nameSection
                    modePicker
                    livePreview
                    contrastSection
                    colorsGrid
                }
                .padding(24)
            }
            Divider()
            footer
        }
        .frame(width: 620, height: 680)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(existingTheme == nil ? "Create Custom Theme" : "Edit Theme")
                    .font(.headline)
                Text("Design custom chrome colors for tabs, toolbar, text and accents.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel", action: onDismiss)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Theme Name")
                .font(.subheadline.weight(.medium))
            HStack {
                TextField("e.g. Sunset Glow, Cyberpunk, Lavender", text: $themeName)
                    .textFieldStyle(.roundedBorder)
                Menu("Presets") {
                    ForEach(BuiltInThemes.all) { preset in
                        Button("Base on \(preset.name)") {
                            if let l = preset.light { lightPalette = EditablePalette(from: l, defaultDark: false) }
                            if let d = preset.dark { darkPalette = EditablePalette(from: d, defaultDark: true) }
                            if themeName.isEmpty { themeName = "\(preset.name) Custom" }
                        }
                    }
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var modePicker: some View {
        Picker("Appearance Mode", selection: $activeMode) {
            ForEach(ThemeMode.allCases, id: \.self) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
    }

    private var livePreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Live Window Preview (\(activeMode.rawValue))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            
            let p = currentPaletteBinding.wrappedValue
            VStack(spacing: 0) {
                // Tab Strip
                HStack(spacing: 8) {
                    // Traffic lights
                    HStack(spacing: 6) {
                        Circle().fill(Color.red).frame(width: 10, height: 10)
                        Circle().fill(Color.yellow).frame(width: 10, height: 10)
                        Circle().fill(Color.green).frame(width: 10, height: 10)
                    }
                    .padding(.leading, 8)

                    // Selected Tab
                    HStack(spacing: 6) {
                        Image(systemName: "globe")
                            .font(.system(size: 10))
                            .foregroundStyle(p.text)
                        Text("Active Tab")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(p.text)
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(p.secondaryText)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(p.selectedTab))

                    // Inactive Tab
                    HStack(spacing: 6) {
                        Image(systemName: "doc")
                            .font(.system(size: 10))
                            .foregroundStyle(p.secondaryText)
                        Text("Background Tab")
                            .font(.system(size: 11))
                            .foregroundStyle(p.secondaryText)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)

                    Spacer()
                }
                .padding(.vertical, 6)
                .background(p.tabStrip)

                // Toolbar
                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left").foregroundStyle(p.secondaryText)
                        Image(systemName: "chevron.right").foregroundStyle(p.secondaryText.opacity(0.5))
                        Image(systemName: "arrow.clockwise").foregroundStyle(p.secondaryText)
                        Image(systemName: "house").foregroundStyle(p.secondaryText)
                    }
                    .font(.system(size: 11))

                    // Address Bar
                    HStack {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(p.secondaryText)
                        Text("paddle://welcome")
                            .font(.system(size: 11))
                            .foregroundStyle(p.text)
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(p.newTabBackground))

                    Circle()
                        .fill(p.accent)
                        .frame(width: 14, height: 14)
                        .overlay(Image(systemName: "arrow.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.white))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(p.toolbar)

                // Page Area
                VStack(spacing: 8) {
                    Text("New Tab Page Background")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(p.text)
                    Text("Hyperlink with accent color")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(p.accent)
                        .underline()
                }
                .frame(maxWidth: .infinity)
                .frame(height: 70)
                .background(p.newTabBackground)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
        }
    }

    private var contrastSection: some View {
        Group {
            if contrastIssues.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("All colors meet WCAG AA contrast standards (4.5:1 text, 3:1 accent).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.green.opacity(0.08)))
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Contrast Warnings (\(contrastIssues.count)):")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    ForEach(contrastIssues, id: \.self) { issue in
                        Text("• \(issue)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.08)))
            }
        }
    }

    private var colorsGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Colors for \(activeMode.rawValue)")
                .font(.subheadline.weight(.medium))

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                colorRow("Tab Strip", color: currentPaletteBinding.tabStrip)
                colorRow("Toolbar", color: currentPaletteBinding.toolbar)
                colorRow("Selected Tab", color: currentPaletteBinding.selectedTab)
                colorRow("Primary Text", color: currentPaletteBinding.text)
                colorRow("Secondary Text", color: currentPaletteBinding.secondaryText)
                colorRow("Accent Color", color: currentPaletteBinding.accent)
                colorRow("New Tab Background", color: currentPaletteBinding.newTabBackground)
            }
        }
    }

    private func colorRow(_ title: String, color: Binding<Color>) -> some View {
        HStack {
            ColorPicker(title, selection: color, supportsOpacity: false)
            Spacer()
            let rgb = EditablePalette.toRGBColor(color.wrappedValue)
            Text(rgb.hex)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", action: onDismiss)
            Button("Save & Apply Theme") {
                saveTheme()
            }
            .buttonStyle(.borderedProminent)
            .disabled(themeName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func saveTheme() {
        let trimmed = themeName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            errorMessage = "Theme name cannot be empty."
            return
        }

        let slug = trimmed.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")

        let id = slug.isEmpty ? "custom-theme" : slug
        if id == "default" || BuiltInThemes.all.contains(where: { $0.id == id }) {
            errorMessage = "Theme name conflicts with a built-in theme. Please pick another name."
            return
        }

        let theme = ChromeTheme(
            id: id,
            name: trimmed,
            light: lightPalette.toThemePalette(),
            dark: darkPalette.toThemePalette()
        )

        do {
            let data = try theme.encode()
            try FileManager.default.createDirectory(at: Paths.themes, withIntermediateDirectories: true)
            let fileURL = Paths.themes.appendingPathComponent("\(id).json")
            if FileManager.default.fileExists(atPath: fileURL.path) {
                // A theme with this id is already there, maybe hand-edited: ask before replacing it.
                let alert = NSAlert()
                alert.messageText = "Replace the theme “\(trimmed)”?"
                alert.informativeText = "The file themes/\(id).json will be replaced."
                alert.addButton(withTitle: "Replace")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            try data.write(to: fileURL, options: .atomic)
            AppModel.shared.themes.load()
            Task {
                await model.saveKey(.theme, .string(id))
                onDismiss()
            }
        } catch {
            errorMessage = "Failed to save theme: \(error.localizedDescription)"
        }
    }
}
