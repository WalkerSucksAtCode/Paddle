import PaddleCore
import SwiftUI

extension EnvironmentValues {
    /// The browser window's text size factor (Settings > Appearance), set once at the root of `BrowserView`.
    @Entry var chromeScale: Double = 1
    /// Config `highContrastTabs`: a stronger fill and edge on the selected tab.
    @Entry var chromeHighContrastTabs = false
    /// Settings > Appearance or the system: the chrome's animations are skipped.
    @Entry var chromeReducesMotion = false
    /// Settings > Appearance or the system: the chrome's materials become solid colors.
    @Entry var chromeReducesTransparency = false
    /// The theme, accent and tint for this window's color scheme; nil is today's look.
    @Entry var chromeTheme: ResolvedChromeTheme?
}

extension Color {
    /// A PaddleCore color as an sRGB SwiftUI color.
    init(rgb: PaddleCore.RGBColor) {
        self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1)
    }
}

/// The active theme's palette for one color scheme as SwiftUI colors. Every field is optional: a nil surface keeps
/// today's look for it. Built at the root of `BrowserView`, so a change applies to every open window.
struct ResolvedChromeTheme: Equatable {
    /// Solid backgrounds, with the tint already blended in (what is drawn is what the cap checked).
    var tabStrip: Color?
    var toolbar: Color?
    var selectedTab: Color?
    var text: Color?
    var secondaryText: Color?
    /// The accent in use: the `accentColor` override, else the theme's.
    var accent: Color?
    /// Black or white, whichever reads better on `accent`.
    var onAccent: Color?
    var newTabBackground: Color?
    /// The tint laid over today's background where the theme gives no tab strip or toolbar color.
    var stripTint: Color?
    var toolbarTint: Color?

    /// Nil when the theme, accent and tint change nothing.
    init?(app: AppModel, dark: Bool) {
        let palette = app.activeTheme?.palette(dark: dark)
        let tint = app.tintChoice.color
        let strength = app.effectiveTintStrength(dark: dark)
        func surface(_ base: PaddleCore.RGBColor?) -> (solid: Color?, overlay: Color?) {
            guard let tint, strength > 0 else { return (base.map { Color(rgb: $0) }, nil) }
            guard let base else { return (nil, Color(rgb: tint).opacity(strength)) }
            return (Color(rgb: base.blended(with: tint, amount: strength)), nil)
        }
        let strip = surface(palette?.tabStrip)
        let bar = surface(palette?.toolbar)
        tabStrip = strip.solid
        stripTint = strip.overlay
        toolbar = bar.solid
        toolbarTint = bar.overlay
        selectedTab = palette?.selectedTab.map { Color(rgb: $0) }
        text = palette?.text.map { Color(rgb: $0) }
        secondaryText = palette?.secondaryText.map { Color(rgb: $0) }
        let accentRGB = app.accentChoice.color ?? palette?.accent
        accent = accentRGB.map { Color(rgb: $0) }
        onAccent = accentRGB.map { Color(rgb: $0.bestText()) }
        newTabBackground = palette?.newTabBackground.map { Color(rgb: $0) }
        let all: [Color?] = [tabStrip, toolbar, selectedTab, text, secondaryText, accent, newTabBackground, stripTint, toolbarTint]
        if all.allSatisfy({ $0 == nil }) { return nil }
    }
}

/// The theme's strip or toolbar color (or the tint over today's look) behind a chrome region, and its text colors.
struct ChromeSurface: ViewModifier {
    enum Kind { case tabStrip, toolbar }
    let kind: Kind
    @Environment(\.chromeTheme) private var theme

    func body(content: Content) -> some View {
        let solid = kind == .tabStrip ? theme?.tabStrip : theme?.toolbar
        let overlay = kind == .tabStrip ? theme?.stripTint : theme?.toolbarTint
        content
            .background {
                ZStack {
                    if let solid { solid }
                    if let overlay { overlay }
                }
            }
            .chromeText(enabled: solid != nil)
    }
}

/// `.primary` and `.secondary` inside this view map to the theme's text colors, when `enabled`.
private struct ChromeText: ViewModifier {
    let enabled: Bool
    @Environment(\.chromeTheme) private var theme

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled, let theme, theme.text != nil || theme.secondaryText != nil {
            content.foregroundStyle(
                theme.text.map { AnyShapeStyle(ThemeTextStyle(color: $0)) } ?? AnyShapeStyle(.primary),
                theme.secondaryText.map { AnyShapeStyle(ThemeTextStyle(color: $0)) } ?? AnyShapeStyle(.secondary)
            )
        } else {
            content
        }
    }
}

/// A theme text color that dims where it is drawn inside a disabled control, as the system label colors do. A plain
/// Color in `foregroundStyle` drew disabled Back / Forward buttons as bright as enabled ones.
private struct ThemeTextStyle: ShapeStyle {
    let color: Color

    func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
        environment.isEnabled ? color : color.opacity(0.35)
    }
}

/// `.font(.system(size:))` times the window's text size factor.
private struct ChromeFont: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    let monospacedDigit: Bool
    @Environment(\.chromeScale) private var scale

    func body(content: Content) -> some View {
        let font = Font.system(size: size * scale, weight: weight, design: design)
        content.font(monospacedDigit ? font.monospacedDigit() : font)
    }
}

/// A background that is a material, or a solid color when transparency is reduced.
private struct ChromeMaterial<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.chromeReducesTransparency) private var reduced

    func body(content: Content) -> some View {
        if reduced {
            content.background(Color(nsColor: .controlBackgroundColor), in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

extension View {
    /// A system font whose point size follows Settings > Appearance > Text size.
    func chromeFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default, monospacedDigit: Bool = false) -> some View {
        modifier(ChromeFont(size: size, weight: weight, design: design, monospacedDigit: monospacedDigit))
    }

    /// `.regularMaterial` behind this view in `shape`, or `controlBackgroundColor` when transparency is reduced.
    func chromeMaterial<S: InsettableShape>(in shape: S) -> some View {
        modifier(ChromeMaterial(shape: shape))
    }

    /// The tab strip or toolbar background of the active theme (and the tint), with the theme's text colors.
    func chromeSurface(_ kind: ChromeSurfaceKind) -> some View {
        modifier(ChromeSurface(kind: kind))
    }

    /// The theme's text colors for `.primary` and `.secondary`, without a background. Pass `enabled: false` when the
    /// theme sets no background behind this view: its text colors were only checked against theme backgrounds.
    func chromeText(enabled: Bool = true) -> some View {
        modifier(ChromeText(enabled: enabled))
    }

    /// The system label colors again, for popovers and dropdowns, which keep the system look instead of the
    /// theme's text colors. Not `.primary` / `.secondary`: those resolve against the theme's style around them.
    func systemText() -> some View {
        foregroundStyle(Color(nsColor: .labelColor), Color(nsColor: .secondaryLabelColor))
    }
}

typealias ChromeSurfaceKind = ChromeSurface.Kind
