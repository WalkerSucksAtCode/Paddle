import Foundation

/// An sRGB color with components 0...1, and the WCAG contrast math the themes are checked with.
public struct RGBColor: Sendable, Equatable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public static let black = RGBColor(red: 0, green: 0, blue: 0)
    public static let white = RGBColor(red: 1, green: 1, blue: 1)

    public init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    /// `#rrggbb` (the `#` is optional, case doesn't matter); nil for anything else.
    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, text.allSatisfy(\.isHexDigit), let value = Int(text, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// `#RRGGBB`.
    public var hex: String {
        func byte(_ c: Double) -> Int { Int((c * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    /// WCAG relative luminance: linearized sRGB weighted 0.2126 / 0.7152 / 0.0722.
    public var relativeLuminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// The WCAG contrast ratio, 1...21, whichever order the colors come in.
    public static func contrast(_ a: RGBColor, _ b: RGBColor) -> Double {
        let (la, lb) = (a.relativeLuminance, b.relativeLuminance)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// A mix in sRGB component space: `amount` 0 is this color, 1 is `other`.
    public func blended(with other: RGBColor, amount: Double) -> RGBColor {
        let t = min(max(amount, 0), 1)
        return RGBColor(
            red: red + (other.red - red) * t,
            green: green + (other.green - green) * t,
            blue: blue + (other.blue - blue) * t
        )
    }

    /// Black or white, whichever contrasts more with this color.
    public func bestText() -> RGBColor {
        RGBColor.contrast(self, .black) >= RGBColor.contrast(self, .white) ? .black : .white
    }
}

/// The seven colors of a theme in one appearance. A user file may leave one out; a missing color keeps the default look.
public struct ThemePalette: Sendable, Equatable {
    public var tabStrip: RGBColor?
    public var toolbar: RGBColor?
    public var selectedTab: RGBColor?
    public var text: RGBColor?
    public var secondaryText: RGBColor?
    public var accent: RGBColor?
    public var newTabBackground: RGBColor?

    /// The seven key names, in file order.
    public static let keys = ["tabStrip", "toolbar", "selectedTab", "text", "secondaryText", "accent", "newTabBackground"]

    public init(
        tabStrip: RGBColor? = nil, toolbar: RGBColor? = nil, selectedTab: RGBColor? = nil, text: RGBColor? = nil,
        secondaryText: RGBColor? = nil, accent: RGBColor? = nil, newTabBackground: RGBColor? = nil
    ) {
        self.tabStrip = tabStrip
        self.toolbar = toolbar
        self.selectedTab = selectedTab
        self.text = text
        self.secondaryText = secondaryText
        self.accent = accent
        self.newTabBackground = newTabBackground
    }

    /// The color for one of `keys`.
    public subscript(key: String) -> RGBColor? {
        get {
            switch key {
            case "tabStrip": tabStrip
            case "toolbar": toolbar
            case "selectedTab": selectedTab
            case "text": text
            case "secondaryText": secondaryText
            case "accent": accent
            case "newTabBackground": newTabBackground
            default: nil
            }
        }
        set {
            switch key {
            case "tabStrip": tabStrip = newValue
            case "toolbar": toolbar = newValue
            case "selectedTab": selectedTab = newValue
            case "text": text = newValue
            case "secondaryText": secondaryText = newValue
            case "accent": accent = newValue
            case "newTabBackground": newTabBackground = newValue
            default: break
            }
        }
    }
}

/// A set of chrome colors for light and dark: one of `BuiltInThemes`, or a `themes/<name>.json` file.
public struct ChromeTheme: Sendable, Equatable, Identifiable {
    /// The `theme` config value: a built-in's id, or a file's base name.
    public var id: String
    /// What Settings shows.
    public var name: String
    /// nil: light mode keeps the default look.
    public var light: ThemePalette?
    /// nil: dark mode keeps the default look.
    public var dark: ThemePalette?
    /// Judged against the stricter selected-tab rule (`ThemeContrast`).
    public var isHighContrast: Bool
    public var isBuiltIn: Bool

    public init(
        id: String, name: String, light: ThemePalette?, dark: ThemePalette?,
        isHighContrast: Bool = false, isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.light = light
        self.dark = dark
        self.isHighContrast = isHighContrast
        self.isBuiltIn = isBuiltIn
    }

    /// The palette for one appearance.
    public func palette(dark isDark: Bool) -> ThemePalette? { isDark ? dark : light }

    public enum DecodeError: Error, Equatable {
        case notAnObject
    }

    /// Reads a theme file: `{"light": {...}, "dark": {...}}` with the seven `ThemePalette.keys`. Data that isn't a JSON
    /// object throws. A missing mode is nil; a missing or unparsable color is a warning and that surface is nil;
    /// unknown keys are ignored.
    public static func decode(id: String, data: Data) throws -> (theme: ChromeTheme, warnings: [String]) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DecodeError.notAnObject }
        var warnings: [String] = []
        func palette(_ mode: String) -> ThemePalette? {
            guard let raw = root[mode] else { return nil }
            guard let object = raw as? [String: Any] else {
                warnings.append("\(mode): not an object")
                return nil
            }
            var result = ThemePalette()
            for key in ThemePalette.keys {
                guard let value = object[key] else { continue }
                if let text = value as? String, let color = RGBColor(hex: text) {
                    result[key] = color
                } else {
                    warnings.append("\(mode).\(key): not a #rrggbb color")
                }
            }
            return result
        }
        let themeName = (root["name"] as? String)?.trimmingCharacters(in: .whitespaces)
        let name = (themeName?.isEmpty == false) ? themeName! : id
        let theme = ChromeTheme(id: id, name: name, light: palette("light"), dark: palette("dark"))
        return (theme, warnings)
    }

    /// Encodes the theme as a JSON object matching `decode`: `{"name": "...", "light": {...}, "dark": {...}}`.
    public func encode() throws -> Data {
        var dict: [String: Any] = ["name": name]
        func paletteDict(_ palette: ThemePalette?) -> [String: String]? {
            guard let palette else { return nil }
            var d: [String: String] = [:]
            for key in ThemePalette.keys {
                if let color = palette[key] {
                    d[key] = color.hex
                }
            }
            return d.isEmpty ? nil : d
        }
        if let light = paletteDict(light) { dict["light"] = light }
        if let dark = paletteDict(dark) { dict["dark"] = dark }
        return try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
    }
}

/// The themes that ship with Paddle. Measured against `ThemeContrast` before they were built.
public enum BuiltInThemes {
    private static func palette(
        _ strip: String, _ toolbar: String, _ selected: String, _ text: String, _ secondary: String, _ accent: String, _ newTab: String
    ) -> ThemePalette {
        ThemePalette(
            tabStrip: RGBColor(hex: strip), toolbar: RGBColor(hex: toolbar), selectedTab: RGBColor(hex: selected),
            text: RGBColor(hex: text), secondaryText: RGBColor(hex: secondary), accent: RGBColor(hex: accent),
            newTabBackground: RGBColor(hex: newTab)
        )
    }

    public static let all: [ChromeTheme] = [
        ChromeTheme(
            id: "graphite", name: "Graphite",
            light: palette("#D5D6D9", "#F0F1F3", "#FFFFFF", "#1D1F22", "#575C63", "#5B6470", "#F7F8F9"),
            dark: palette("#141517", "#222326", "#3D3F44", "#ECEDEF", "#A7ABB1", "#9AA3AE", "#1C1D20"),
            isBuiltIn: true),
        ChromeTheme(
            id: "ocean", name: "Ocean",
            light: palette("#C9DAEA", "#E6EFF7", "#FFFFFF", "#0E2233", "#3B5469", "#0A64AD", "#F2F7FB"),
            dark: palette("#0B1621", "#152433", "#2D4560", "#E6EEF5", "#9DB2C5", "#5AAEF0", "#111E2B"),
            isBuiltIn: true),
        ChromeTheme(
            id: "forest", name: "Forest",
            light: palette("#C8DAC8", "#E9F1E8", "#FFFFFF", "#142414", "#42564A", "#2A7230", "#F3F8F2"),
            dark: palette("#0D160F", "#17241A", "#2E4432", "#E5F0E6", "#9FB8A3", "#6CC070", "#131F15"),
            isBuiltIn: true),
        ChromeTheme(
            id: "dusk", name: "Dusk",
            light: palette("#DCD2EC", "#EEE9F6", "#FFFFFF", "#221A33", "#554A69", "#6A40BD", "#F7F4FB"),
            dark: palette("#130F1A", "#211A2C", "#3D3251", "#EEE8F7", "#B3A8C7", "#A88BEB", "#1B1525"),
            isBuiltIn: true),
        ChromeTheme(
            id: "sand", name: "Sand",
            light: palette("#E0D2B6", "#F4EEE1", "#FFFDF8", "#2B2216", "#5E513C", "#A0561A", "#FAF6EE"),
            dark: palette("#19150E", "#272117", "#463C2C", "#F3ECDF", "#C2B6A0", "#E0A060", "#211C14"),
            isBuiltIn: true),
        ChromeTheme(
            id: "high-contrast", name: "High Contrast",
            light: palette("#FFFFFF", "#FFFFFF", "#8C8C8C", "#000000", "#333333", "#0040DD", "#FFFFFF"),
            dark: palette("#000000", "#000000", "#6E6E6E", "#FFFFFF", "#D0D0D0", "#4DA3FF", "#000000"),
            isHighContrast: true, isBuiltIn: true),
    ]
}

/// The contrast rules a theme is held to, and the cap on how far a tint may go.
public struct ThemeContrast {
    /// Rules a palette breaks, as "text on tabStrip 3.10:1, needs 4.5:1". Pairs with a missing color are skipped.
    /// `highContrast` raises the selected tab's required difference from the strip from 1.4 to 3.
    public static func issues(_ palette: ThemePalette, highContrast: Bool) -> [String] {
        var found: [String] = []
        func check(_ foreground: String, on background: String, needs: Double) {
            guard let f = palette[foreground], let b = palette[background] else { return }
            let ratio = RGBColor.contrast(f, b)
            if ratio < needs {
                found.append(String(format: "%@ on %@ %.2f:1, needs %g:1", foreground, background, ratio, needs))
            }
        }
        for background in ["tabStrip", "toolbar", "selectedTab", "newTabBackground"] {
            check("text", on: background, needs: 4.5)
        }
        for background in ["tabStrip", "toolbar", "newTabBackground"] {
            check("secondaryText", on: background, needs: 4.5)
        }
        for background in ["toolbar", "newTabBackground"] {
            check("accent", on: background, needs: 3)
        }
        check("selectedTab", on: "tabStrip", needs: highContrast ? 3 : 1.4)
        return found
    }

    /// The largest strength (0...1, in 1 % steps) up to `requested` at which `text` stays at 4.5:1 and `secondaryText`
    /// at 3:1 on `base` blended with `tint`. 0 when even a trace of tint is too much.
    public static func maxTintStrength(
        base: RGBColor, tint: RGBColor, text: RGBColor, secondaryText: RGBColor?, requested: Double
    ) -> Double {
        let wanted = min(max(requested, 0), 1)
        func readable(_ strength: Double) -> Bool {
            let surface = base.blended(with: tint, amount: strength)
            if RGBColor.contrast(text, surface) < 4.5 { return false }
            if let secondaryText, RGBColor.contrast(secondaryText, surface) < 3 { return false }
            return true
        }
        if readable(wanted) { return wanted }
        var step = Int((wanted * 100).rounded(.down))
        while step > 0 {
            let strength = Double(step) / 100
            if strength < wanted, readable(strength) { return strength }
            step -= 1
        }
        return 0
    }
}

/// Measured approximations of the default look (no theme), used to cap a tint over it.
public enum DefaultChromeColors {
    public static let lightBase = RGBColor(hex: "#FFFFFF")!
    public static let lightText = RGBColor(hex: "#262626")!
    public static let lightSecondary = RGBColor(hex: "#808080")!
    public static let darkBase = RGBColor(hex: "#1E1E1E")!
    public static let darkText = RGBColor(hex: "#DDDDDD")!
    public static let darkSecondary = RGBColor(hex: "#9A9A9A")!

    public static func base(dark: Bool) -> RGBColor { dark ? darkBase : lightBase }
    public static func text(dark: Bool) -> RGBColor { dark ? darkText : lightText }
    public static func secondary(dark: Bool) -> RGBColor { dark ? darkSecondary : lightSecondary }
}

/// Named accent and tint colors.
public enum ColorPreset: String, CaseIterable, Sendable {
    case blue, purple, pink, red, orange, yellow, green, graphite

    public var displayName: String { rawValue.capitalized }

    public var color: RGBColor {
        let hex = switch self {
        case .blue: "#007AFF"
        case .purple: "#AF52DE"
        case .pink: "#FF2D55"
        case .red: "#FF3B30"
        case .orange: "#FF9500"
        case .yellow: "#FFCC00"
        case .green: "#34C759"
        case .graphite: "#8E8E93"
        }
        return RGBColor(hex: hex)!
    }
}

/// The value of `accentColor` or `chromeTint`: the automatic one ("system" for the accent, "none" for the tint),
/// a preset by name, or `#rrggbb`.
public enum ColorChoice: Sendable, Equatable, Hashable {
    case automatic
    case preset(ColorPreset)
    case custom(RGBColor)

    /// nil when `configValue` is none of the three.
    public init?(configValue: String, automaticValue: String) {
        let text = configValue.trimmingCharacters(in: .whitespaces).lowercased()
        if text == automaticValue {
            self = .automatic
        } else if let preset = ColorPreset(rawValue: text) {
            self = .preset(preset)
        } else if text.hasPrefix("#"), let color = RGBColor(hex: text) {
            self = .custom(color)
        } else {
            return nil
        }
    }

    /// What goes in config.json.
    public func configValue(automaticValue: String) -> String {
        switch self {
        case .automatic: automaticValue
        case .preset(let preset): preset.rawValue
        case .custom(let color): color.hex.lowercased()
        }
    }

    /// The color, or nil for automatic.
    public var color: RGBColor? {
        switch self {
        case .automatic: nil
        case .preset(let preset): preset.color
        case .custom(let color): color
        }
    }
}
