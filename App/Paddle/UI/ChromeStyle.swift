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
}
